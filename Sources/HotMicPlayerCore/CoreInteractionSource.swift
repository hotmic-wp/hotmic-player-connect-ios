import Foundation
import Observation
import HotMicCore
import HotMicPlayer

/// HotMic VOD engagement. Use one source per player and authenticated user.
/// Only current and next own sessions; timeline access never opens a session.
@MainActor @Observable public final class CoreInteractionSource: HMInteractionSource {
    public enum ConnectionState: Equatable, Sendable {
        case idle, starting, connected, reconnecting(attempt: Int), disconnected, failed
    }
    private var states: [String: ConnectionState] = [:]
    @ObservationIgnored private let factory: any CoreSessionFactory
    @ObservationIgnored private var current: HMMediaItem?
    @ObservationIgnored private var next: HMMediaItem?
    @ObservationIgnored private var slots: [String: Slot] = [:]
    @ObservationIgnored private var timelines: [String: WeakTimeline] = [:]
    @ObservationIgnored private var reconciliation: Task<Void, Never>?
    @ObservationIgnored private var failed: Set<String> = []

    public convenience init(client: HotMicClient) { self.init(factory: LiveCoreSessionFactory(client: client)) }
    @_spi(Testing) public init(factory: any CoreSessionFactory) { self.factory = factory }

    deinit {
        reconciliation?.cancel()
        for slot in slots.values {
            Task { @MainActor in
                slot.startTask?.cancel(); slot.eventTask?.cancel()
                await slot.session.stop()
            }
        }
    }

    /// Connection failures affect engagement only. Re-entering an item retries with a new session.
    public func connectionState(for item: HMMediaItem) -> ConnectionState { states[item.id] ?? .idle }
    public func capabilities(for item: HMMediaItem) -> HMEngagementCapabilities {
        streamID(for: item) == nil ? .readOnly : [.sendChat, .reactToMessage, .vote]
    }
    public func timeline(for item: HMMediaItem) -> any HMStreamTimeline { store(for: item) }
    public func polls(for item: HMMediaItem) -> [HMPoll] { Array(store(for: item).polls.values) }
    public func engagementDidLoad(_ engagement: HMEngagement) {
        let timeline = store(for: engagement.item)
        timeline.engagement = engagement
        for poll in timeline.polls.values { engagement.upsertPoll(poll) }
        for chat in timeline.messages.values { engagement.updateReactions(chat.counts, forMessage: chat.id) }
        // Deletions can arrive during next-item preparation, before the UI asks for engagement.
        for event in timeline.pendingDeletions { applyDeletion(event, to: timeline) }
        timeline.pendingDeletions.removeAll()
    }
    public func willBecomeNext(_ item: HMMediaItem) { next = item; scheduleReconciliation() }
    public func didBecomeCurrent(_ item: HMMediaItem) {
        current = item
        if next?.id == item.id { next = nil }
        scheduleReconciliation()
    }
    public func didLeave(_ item: HMMediaItem) {
        if current?.id == item.id { current = nil }
        if next?.id == item.id { next = nil }
        failed.remove(item.id)
        scheduleReconciliation()
    }

    public func sendChat(_ text: String, for item: HMMediaItem) async throws {
        let timeline = store(for: item)
        let message = HMChatMessage(id: UUID().uuidString, author: "You", text: text,
                                    offset: timeline.engagement?.currentMediaTime ?? 0)
        if let event = try await sendChat(message, for: item) { timeline.engagement?.receive(event) }
    }
    public func sendChat(_ message: HMChatMessage, for item: HMMediaItem) async throws -> HMTimelineEvent? {
        let slot = try activeSlot(for: item)
        let confirmed = try await slot.session.sendChat(message.text)
        // Keep a confirmed send at the viewer's playback position, not today's wall time on an old VOD.
        slot.timeline.ownOffsets[confirmed.id] = slot.timeline.clamp(message.offset)
        slot.timeline.messages[confirmed.id] = confirmed
        let event = slot.timeline.event(confirmed)
        slot.timeline.append(event)
        return event
    }
    public func react(_ emoji: String, toMessage messageID: String, for item: HMMediaItem) async throws {
        guard let type = Self.types[emoji] else { throw HMInteractionError.unsupportedAction }
        let slot = try activeSlot(for: item)
        let reaction = try await slot.session.addReaction(type, to: messageID)
        applyReaction(reaction, added: true, to: slot)
    }
    public func vote(pollID: String, optionID: String, for item: HMMediaItem) async throws {
        let slot = try activeSlot(for: item)
        try await slot.session.vote(pollID: pollID, optionID: optionID)
        // Core emits pollUpdated with myAnswer; the engagement owns optimistic vote/rollback.
    }

    private static let types = ["👍": "like", "🔥": "fire", "😆": "laugh", "😡": "anger", "😢": "sadness"]
    private static func emoji(_ type: String) -> String? { types.first { $0.value == type }?.key }

    private func streamID(for item: HMMediaItem) -> String? {
        if case .reference(let namespace, let id) = item.source { return namespace == "hotmic" ? id : nil }
        // CorePlaylistSource keeps direct URLs, carrying their originating reference explicitly.
        if item.metadata["hotmic.namespace"] == "hotmic" { return item.metadata["hotmic.streamID"] }
        if let original = [current, next].compactMap({ $0 }).first(where: { $0.id == item.id }),
           case .reference("hotmic", let id) = original.source { return id }
        return nil
    }
    private func store(for item: HMMediaItem) -> CoreTimeline {
        let streamID = streamID(for: item)
        if let existing = timelines[item.id]?.value, existing.streamID == streamID { return existing }
        timelines = timelines.filter { $0.value.value != nil }
        let timeline = CoreTimeline(streamID: streamID, duration: item.durationHint ?? 0)
        timelines[item.id] = WeakTimeline(timeline)
        return timeline
    }
    private func activeSlot(for item: HMMediaItem) throws -> Slot {
        guard streamID(for: item) != nil else { throw HMInteractionError.unsupportedAction }
        guard let slot = slots[item.id], slot.ready, !slot.stopping else { throw HotMicError.invalidSessionState }
        return slot
    }
    private func scheduleReconciliation() {
        guard reconciliation == nil else { return }
        // Coalesce synchronous hooks (including a backward swipe's current/next role swap).
        reconciliation = Task { @MainActor [weak self] in
            await self?.reconcile()
        }
    }
    private func reconcile() async {
        while !Task.isCancelled {
            let wanted = [current, next].compactMap { $0 }.filter { streamID(for: $0) != nil && !failed.contains($0.id) }
            if let obsolete = slots.first(where: { entry in
                !wanted.contains { $0.id == entry.key && streamID(for: $0) == entry.value.timeline.streamID }
            }) {
                let slot = obsolete.value
                slot.stopping = true; slot.startTask?.cancel(); slot.eventTask?.cancel()
                // Count this slot until Core's async cleanup has completed, before opening any replacement.
                await slot.session.stop()
                slots[obsolete.key] = nil
                if !failed.contains(obsolete.key) { states[obsolete.key] = nil }
                continue // Roles may have changed while stop suspended.
            }
            for item in wanted where slots[item.id] == nil {
                guard slots.count < 2 else { break }
                let timeline = store(for: item)
                guard let streamID = timeline.streamID else { continue }
                let slot = Slot(session: factory.makeSession(streamID: streamID), timeline: timeline)
                slots[item.id] = slot; states[item.id] = .starting
                let events = slot.session.events // subscribe BEFORE start
                slot.eventTask = Task { @MainActor [weak self, weak slot] in
                    for await event in events {
                        guard let self, let slot, !Task.isCancelled, self.slots[item.id] === slot, !slot.stopping else { return }
                        self.consume(event, itemID: item.id, slot: slot)
                    }
                }
                let session = slot.session
                slot.startTask = Task { @MainActor [weak self, weak slot] in
                    do {
                        let snapshot = try await session.start()
                        guard let self, let slot, !Task.isCancelled, self.slots[item.id] === slot, !slot.stopping else { return }
                        slot.userID = snapshot.userID
                        slot.timeline.retime(liveDate: snapshot.liveDate, duration: snapshot.duration)
                        snapshot.messages.forEach { self.receive($0, in: slot) }
                        snapshot.polls.forEach { self.upsert($0, in: slot) }
                        slot.ready = true
                        let queued = slot.queued; slot.queued.removeAll()
                        for event in queued { self.consume(event, itemID: item.id, slot: slot) }
                    } catch {
                        guard let self, let slot, !slot.stopping, self.slots[item.id] === slot else { return }
                        self.fail(item.id)
                    }
                }
            }
            break
        }
        reconciliation = nil
        timelines = timelines.filter { $0.value.value != nil }
        let retained = Set([current?.id, next?.id].compactMap { $0 }).union(slots.keys)
        states = states.filter { retained.contains($0.key) }
    }
    private func fail(_ id: String) {
        slots[id]?.ready = false
        failed.insert(id); states[id] = .failed
        scheduleReconciliation()
    }
    private func consume(_ event: CoreSessionEvent, itemID: String, slot: Slot) {
        switch event {
        case .connection(let state): states[itemID] = state; return
        case .failed: fail(itemID); return
        case .deleted, .ended:
            failed.insert(itemID); states[itemID] = .disconnected; scheduleReconciliation(); return
        default: break
        }
        guard slot.ready else { slot.queued.append(event); return }
        switch event {
        case .chat(let messages, let reactions):
            messages.forEach { receive($0, in: slot) }
            reactions.forEach { applyReaction($0, added: true, to: slot) }
        case .messageDeleted(let id):
            slot.timeline.remove(id)
            deletion(event, timeline: slot.timeline)
        case .reactionDeleted(let reaction): applyReaction(reaction, added: false, to: slot)
        case .poll(let poll): upsert(poll, in: slot)
        case .pollDeleted(let id):
            slot.timeline.polls[id] = nil
            deletion(event, timeline: slot.timeline)
        case .stream(let date, let duration):
            slot.timeline.retime(liveDate: date, duration: duration)
            for message in slot.timeline.messages.values { slot.timeline.engagement?.receive(slot.timeline.event(message)) }
        default: break
        }
    }
    private func receive(_ chat: CoreChat, in slot: Slot) {
        slot.timeline.messages[chat.id] = chat
        let event = slot.timeline.event(chat)
        if let engagement = slot.timeline.engagement {
            engagement.receive(event)
            engagement.updateReactions(chat.counts, forMessage: chat.id)
        } else { slot.timeline.append(event) }
    }
    private func upsert(_ poll: CorePoll, in slot: Slot) {
        let mapped = HMPoll(id: poll.id, question: poll.question,
                            options: poll.options.map { .init(id: $0.id, text: $0.text, votes: max(0, $0.votes)) },
                            viewerVote: poll.viewerVote, opensAt: slot.timeline.offset(poll.createdAt), isClosed: poll.closed)
        slot.timeline.polls[poll.id] = mapped
        slot.timeline.engagement?.upsertPoll(mapped)
    }
    private func applyReaction(_ reaction: CoreMessageReaction, added: Bool, to slot: Slot) {
        guard let emoji = Self.emoji(reaction.type) else { return }
        let key = ReactionKey(message: reaction.messageID, user: reaction.userID, type: reaction.type)
        guard slot.reactionState[key] != added else { return }
        slot.reactionState[key] = added
        let timeline = slot.timeline
        if !added {
            // Apply the delta before replacing totals, so the viewer's selection is cleared too.
            timeline.engagement?.removeReaction(emoji, forMessage: reaction.messageID,
                                                isOwn: reaction.userID == slot.userID)
        }
        if var chat = timeline.messages[reaction.messageID] {
            chat.counts[emoji] = max(0, (chat.counts[emoji] ?? 0) + (added ? 1 : -1))
            timeline.messages[chat.id] = chat
            timeline.append(timeline.event(chat))
            timeline.engagement?.updateReactions(chat.counts, forMessage: chat.id)
        }
    }
    private func deletion(_ event: CoreSessionEvent, timeline: CoreTimeline) {
        if timeline.engagement == nil { timeline.pendingDeletions.append(event) }
        else { applyDeletion(event, to: timeline) }
    }
    private func applyDeletion(_ event: CoreSessionEvent, to timeline: CoreTimeline) {
        switch event {
        case .messageDeleted(let id): timeline.engagement?.removeMessage(id: id)
        case .pollDeleted(let id): timeline.engagement?.removePoll(id: id)
        default: break
        }
    }
}

@MainActor private final class Slot {
    let session: any CoreSession
    let timeline: CoreTimeline
    var startTask: Task<Void, Never>?
    var eventTask: Task<Void, Never>?
    var queued: [CoreSessionEvent] = []
    var ready = false
    var stopping = false
    var userID = ""
    var reactionState: [ReactionKey: Bool] = [:]
    init(session: any CoreSession, timeline: CoreTimeline) { self.session = session; self.timeline = timeline }
}
private struct ReactionKey: Hashable { let message: String; let user: String; let type: String }
@MainActor private final class WeakTimeline {
    weak var value: CoreTimeline?
    init(_ value: CoreTimeline) { self.value = value }
}
