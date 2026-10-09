import Foundation
import HotMicPlayer

@MainActor final class CoreTimeline: HMStreamTimeline {
    let streamID: String?
    var duration: TimeInterval
    var liveDate: Date?
    weak var engagement: HMEngagement?
    var polls: [String: HMPoll] = [:]
    var messages: [String: CoreChat] = [:]
    // Keep viewer offsets when Core later supplies the same message's wall time.
    var pendingDeletions: [CoreSessionEvent] = []
    var ownOffsets: [String: TimeInterval] = [:]
    private var byID: [String: HMTimelineEvent] = [:]
    private var ordered: [HMTimelineEvent] = []
    private(set) var density: [HMDensityBucket] = []
    private(set) var markers: [HMTimelineMarker] = []
    private(set) var rebuildCount = 0

    init(streamID: String?, duration: TimeInterval, liveDate: Date? = nil) {
        self.streamID = streamID; self.duration = Self.validDuration(duration); self.liveDate = liveDate
    }
    static func validDuration(_ value: TimeInterval) -> TimeInterval { value.isFinite ? max(0, value) : 0 }
    func offset(_ date: Date) -> TimeInterval? {
        // 0.4.1 has no non-timed engagement representation. Drop unlocatable history.
        guard let liveDate else { return nil }
        let offset = date.timeIntervalSince(liveDate)
        guard offset.isFinite, (0...duration).contains(offset) else { return nil }
        return offset
    }
    func clamp(_ time: TimeInterval) -> TimeInterval { time.isFinite ? min(duration, max(0, time)) : 0 }
    func event(_ chat: CoreChat) -> HMTimelineEvent? {
        guard let offset = ownOffsets[chat.id] ?? offset(chat.createdAt) else { return nil }
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
        if isBatching { batchChanged = true } else { rebuild() }
    }
    func append(contentsOf events: [HMTimelineEvent], receive: ((HMTimelineEvent) -> Void)? = nil) {
        // Let engagement accept each event before append, preserving its moderation guard.
        // The synchronous batch cannot yield to UI queries before the ordered index is rebuilt.
        precondition(!isBatching)
        isBatching = true; batchChanged = false
        for event in events {
            if let receive { receive(event) } else { append(event) }
        }
        isBatching = false
        if batchChanged { rebuild() }
    }
    private func withBaseReactions(_ event: HMTimelineEvent) -> HMTimelineEvent {
        guard let original = byID[event.id] else { return event }
        return HMTimelineEvent(id: event.id, offset: event.offset, kind: event.kind,
                               author: event.author, text: event.text, emoji: event.emoji,
                               magnitude: event.magnitude, avatarURL: event.avatarURL,
                               wallTime: event.wallTime, reactions: original.reactions)
    }
    func remove(_ id: String) {
        messages[id] = nil
        if byID.removeValue(forKey: id) != nil { rebuild() }
    }
    func retime(liveDate: Date?, duration: TimeInterval?) {
        let duration = duration.map(Self.validDuration) ?? self.duration
        guard self.liveDate != liveDate || self.duration != duration else { return }
        self.liveDate = liveDate; self.duration = duration
        for id in Array(byID.keys) {
            guard let chat = messages[id] else { continue }
            byID[id] = event(chat).map(withBaseReactions)
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
            let bucket = min(count - 1, Int(max(0, event.offset) / max(1, duration) * Double(count)))
            totals[bucket] += max(1, event.magnitude)
        }
        let peak = max(1, totals.max() ?? 1)
        density = totals.enumerated().map { HMDensityBucket(index: $0.offset, position: Double($0.offset) / Double(count),
                                                           intensity: Double($0.element) / Double(peak), dominantEmoji: nil, eventCount: $0.element) }
        // Chat density is shown; Core has no stream emoji events or authored highlights.
        markers = []
    }
}
