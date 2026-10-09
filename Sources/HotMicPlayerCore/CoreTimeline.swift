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

    init(streamID: String?, duration: TimeInterval, liveDate: Date? = nil) {
        self.streamID = streamID; self.duration = Self.validDuration(duration); self.liveDate = liveDate
    }
    static func validDuration(_ value: TimeInterval) -> TimeInterval { value.isFinite ? max(0, value) : 0 }
    func offset(_ date: Date) -> TimeInterval {
        // Without a stream origin Core cannot locate history on the media clock.
        guard let liveDate else { return 0 }
        return clamp(date.timeIntervalSince(liveDate))
    }
    func clamp(_ time: TimeInterval) -> TimeInterval { time.isFinite ? min(duration, max(0, time)) : 0 }
    func event(_ chat: CoreChat) -> HMTimelineEvent {
        HMTimelineEvent(id: chat.id, offset: ownOffsets[chat.id] ?? offset(chat.createdAt), kind: .chat,
                        author: chat.author, text: chat.text, avatarURL: chat.avatar,
                        wallTime: chat.createdAt, reactions: chat.counts.filter { $0.value > 0 })
    }
    func append(_ event: HMTimelineEvent) {
        // Engagement reaction overlays are measured from the first event's base.
        // Preserve it when replacing text/offset; authoritative totals travel via updateReactions.
        byID[event.id] = withBaseReactions(event)
        rebuild()
    }
    private func withBaseReactions(_ event: HMTimelineEvent) -> HMTimelineEvent {
        guard let original = byID[event.id] else { return event }
        return HMTimelineEvent(id: event.id, offset: event.offset, kind: event.kind,
                               author: event.author, text: event.text, emoji: event.emoji,
                               magnitude: event.magnitude, avatarURL: event.avatarURL,
                               wallTime: event.wallTime, reactions: original.reactions)
    }
    func remove(_ id: String) { byID[id] = nil; messages[id] = nil; rebuild() }
    func retime(liveDate: Date?, duration: TimeInterval?) {
        self.liveDate = liveDate
        if let duration { self.duration = Self.validDuration(duration) }
        for chat in messages.values { byID[chat.id] = withBaseReactions(event(chat)) }
        rebuild()
    }
    func events(in range: ClosedRange<TimeInterval>) -> [HMTimelineEvent] {
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
