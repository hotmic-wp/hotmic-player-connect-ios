import Foundation
import Observation
import HotMicPlayer

@MainActor final class CoreTimeline: HMStreamTimeline {
    let streamID: String?
    private var knownDuration: TimeInterval = 0
    var duration: TimeInterval { knownDuration }
    var liveDate: Date?
    weak var engagement: HMEngagement? { didSet { observeDurationHint() } }
    var polls: [String: HMPoll] = [:]
    var messages: [String: _CoreChat] = [:]
    private var rawPolls: [String: _CorePoll] = [:]
    private var messageOrder: [String] = []
    private var pollOrder: [String] = []
    // Bounds apply while timing is unknown as well as after mapping.
    static let messageCapacity = 2_000
    static let pollCapacity = 100
    // Keep viewer offsets when Core later supplies the same message's wall time.
    var pendingDeletions: [_CoreSessionEvent] = []
    var ownOffsets: [String: TimeInterval] = [:]
    private var byID: [String: HMTimelineEvent] = [:]
    private var acceptedIDs: Set<String> = []
    private var ordered: [HMTimelineEvent] = []
    private var densityValues: [HMDensityBucket] = []
    var density: [HMDensityBucket] { densityValues }
    private(set) var markers: [HMTimelineMarker] = []
    private(set) var rebuildCount = 0

    init(streamID: String?, duration: TimeInterval, liveDate: Date? = nil) {
        self.streamID = streamID; self.knownDuration = Self.validDuration(duration); self.liveDate = liveDate
    }
    static func validDuration(_ value: TimeInterval) -> TimeInterval { value.isFinite ? max(0, value) : 0 }
    func offset(_ date: Date) -> TimeInterval? {
        // History waits for usable timing; raw values remain bounded in this store.
        guard let liveDate, knownDuration > 0 else { return nil }
        let offset = date.timeIntervalSince(liveDate)
        guard offset.isFinite, (0...knownDuration).contains(offset) else { return nil }
        return offset
    }
    func clamp(_ time: TimeInterval) -> TimeInterval {
        guard time.isFinite else { return 0 }
        return knownDuration > 0 ? min(knownDuration, max(0, time)) : max(0, time)
    }
    func supplyDuration(_ value: TimeInterval?) {
        guard knownDuration == 0, let value, Self.validDuration(value) > 0 else { return }
        retime(liveDate: liveDate, duration: value)
    }
    private func observeDurationHint() {
        guard knownDuration == 0 else { return }
        supplyDuration(engagement?.item.durationHint)
        guard knownDuration == 0 else { return }
        // The player updates engagement.item after reference resolution without another timeline call.
        // Schedule remapping after observation fires, outside a SwiftUI query/render pass.
        let hint = withObservationTracking {
            engagement?.item.durationHint
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeDurationHint() }
        }
        supplyDuration(hint)
    }
    func remember(_ chat: _CoreChat) {
        if messages[chat.id] == nil { messageOrder.append(chat.id) }
        messages[chat.id] = chat
        while messageOrder.count > Self.messageCapacity {
            let id = messageOrder.removeFirst()
            messages[id] = nil; ownOffsets[id] = nil; acceptedIDs.remove(id)
            if byID.removeValue(forKey: id) != nil { batchChanged = true }
        }
    }
    func remember(_ poll: _CorePoll) {
        if rawPolls[poll.id] == nil { pollOrder.append(poll.id) }
        rawPolls[poll.id] = poll
        while pollOrder.count > Self.pollCapacity {
            let id = pollOrder.removeFirst()
            rawPolls[id] = nil; polls[id] = nil
            // A retention eviction must not install a permanent moderation tombstone.
        }
        mapPoll(poll)
    }
    private func mapPoll(_ poll: _CorePoll) {
        guard let offset = offset(poll.createdAt) else { return }
        let mapped = HMPoll(id: poll.id, question: poll.question,
                            options: poll.options.map { .init(id: $0.id, text: $0.text, votes: max(0, $0.votes)) },
                            viewerVote: poll.viewerVote, opensAt: offset, isClosed: poll.closed)
        polls[poll.id] = mapped
        engagement?.upsertPoll(mapped)
    }
    func removePoll(_ id: String) {
        rawPolls[id] = nil; polls[id] = nil; pollOrder.removeAll { $0 == id }
    }
    func event(_ chat: _CoreChat) -> HMTimelineEvent? {
        guard let offset = ownOffsets[chat.id].map(clamp) ?? offset(chat.createdAt) else { return nil }
        return HMTimelineEvent(id: chat.id, offset: offset, kind: .chat,
                               author: chat.author, text: chat.text, avatarURL: chat.avatar,
                               wallTime: chat.createdAt, reactions: chat.counts.filter { $0.value > 0 })
    }
    private var isBatching = false
    private var batchChanged = false
    func append(_ event: HMTimelineEvent) {
        // Keep the first reaction base; authoritative totals use updateReactions.
        let mapped = withBaseReactions(event)
        guard byID[event.id] != mapped else { return }
        byID[event.id] = mapped
        acceptedIDs.insert(event.id)
        if isBatching { batchChanged = true } else { rebuild() }
    }
    func append(contentsOf events: [HMTimelineEvent], receive: ((HMTimelineEvent) -> Void)? = nil) {
        // Let engagement accept each event before append, preserving its moderation guard.
        // The synchronous batch cannot yield to UI queries before the ordered index is rebuilt.
        precondition(!isBatching)
        isBatching = true
        for event in events {
            if let receive { receive(event) } else { append(event) }
        }
        isBatching = false
        if batchChanged { rebuild() }
        batchChanged = false
    }
    private func withBaseReactions(_ event: HMTimelineEvent) -> HMTimelineEvent {
        guard let original = byID[event.id] else { return event }
        return HMTimelineEvent(id: event.id, offset: event.offset, kind: event.kind,
                               author: event.author, text: event.text, emoji: event.emoji,
                               magnitude: event.magnitude, avatarURL: event.avatarURL,
                               wallTime: event.wallTime, reactions: original.reactions)
    }
    func remove(_ id: String) {
        messages[id] = nil; ownOffsets[id] = nil; acceptedIDs.remove(id); messageOrder.removeAll { $0 == id }
        if byID.removeValue(forKey: id) != nil { rebuild() }
    }
    func retime(liveDate: Date?, duration: TimeInterval?) {
        // Missing/invalid updates must not erase an already useful duration.
        let duration = duration.map(Self.validDuration).flatMap { $0 > 0 ? $0 : nil } ?? knownDuration
        guard self.liveDate != liveDate || knownDuration != duration else { return }
        self.liveDate = liveDate; knownDuration = duration
        for id in acceptedIDs {
            guard let chat = messages[id] else { continue }
            byID[id] = event(chat).map(withBaseReactions)
        }
        // New mappings still pass the player's moderation guard; accepted IDs are updated above.
        let mapped = messages.values.compactMap(event)
        if let engagement {
            append(contentsOf: mapped) { engagement.receive($0) }
            for chat in messages.values { engagement.updateReactions(chat.counts, forMessage: chat.id) }
        } else { append(contentsOf: mapped) }
        for poll in Array(rawPolls.values) {
            if liveDate != nil, knownDuration > 0, offset(poll.createdAt) == nil {
                let wasMapped = polls[poll.id] != nil
                removePoll(poll.id)
                if wasMapped { engagement?.removePoll(id: poll.id) }
            } else { mapPoll(poll) }
        }
        rebuild()
    }
    func events(in range: ClosedRange<TimeInterval>) -> [HMTimelineEvent] {
        // During receive, the SDK checks exact-offset membership after append. Its other
        // synchronous batch reads are ID lookups; they do not require media-time ordering.
        if isBatching { return byID.values.filter { range.contains($0.offset) } }
        var low = 0, high = ordered.count
        while low < high {
            let mid = (low + high) / 2
            if ordered[mid].offset < range.lowerBound { low = mid + 1 } else { high = mid }
        }
        var end = low
        while end < ordered.count, ordered[end].offset <= range.upperBound { end += 1 }
        return Array(ordered[low..<end])
    }
    private func rebuild() {
        rebuildCount += 1
        ordered = byID.values.sorted { $0.offset == $1.offset ? $0.id < $1.id : $0.offset < $1.offset }
        let count = 60
        var totals = [Int](repeating: 0, count: count)
        for event in ordered {
            let bucket = Int(min(Double(count - 1), max(0, event.offset) / max(1, knownDuration) * Double(count)))
            totals[bucket] += max(1, event.magnitude)
        }
        let peak = max(1, totals.max() ?? 1)
        densityValues = totals.enumerated().map { HMDensityBucket(index: $0.offset, position: Double($0.offset) / Double(count),
                                                           intensity: Double($0.element) / Double(peak), dominantEmoji: nil, eventCount: $0.element) }
        // Chat density is shown; Core has no stream emoji events or authored highlights.
        markers = []
    }
}
