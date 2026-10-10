import Foundation
import Observation
import HotMicCore
import HotMicPlayer

/// HotMic VOD engagement. Use one source per player and authenticated user.
/// Only current and next own sessions; timeline access never opens a session.
@MainActor @Observable public final class HotMicInteractionSource: HMInteractionSource {
    /// Engagement connection status, independent of media playback. Main-actor reads; Sendable values.
    public enum ConnectionState: Equatable, Sendable {
        /// No session is active.
        case idle
        /// A session is loading its snapshot.
        case starting
        /// Core is connected.
        case connected
        /// Core is retrying polling within the session.
        case reconnecting(attempt: Int)
        /// The session has disconnected or ended.
        case disconnected
        /// Startup failed; transient failures retry while current.
        case failed
    }
    private var states: [String: ConnectionState] = [:]
    @ObservationIgnored private let factory: any _HotMicSessionFactory
    @ObservationIgnored private var current: HMMediaItem?
    @ObservationIgnored private var next: HMMediaItem?
    @ObservationIgnored private var slots: [String: Slot] = [:]
    @ObservationIgnored private var timelines: [String: WeakTimeline] = [:]
    @ObservationIgnored private var reconciliation: Task<Void, Never>?
    @ObservationIgnored private var failed: Set<String> = []
    @ObservationIgnored private var currentSince: ContinuousClock.Instant?
    @ObservationIgnored private var wake: Task<Void, Never>?
    @ObservationIgnored private var retryAt: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var attempts: [String: Int] = [:]
    @ObservationIgnored private let retryBaseDelay: TimeInterval
    /// Current-item dwell before opening next. Zero opts into immediate preparation.
    public let nextSessionDelay: TimeInterval

    /// Creates engagement sharing the host's authenticated client. Access on the main actor.
    public convenience init(client: HotMicClient, nextSessionDelay: TimeInterval = 1) {
        self.init(factory: LiveHotMicSessionFactory(client: client), nextSessionDelay: nextSessionDelay)
    }
    package init(factory: any _HotMicSessionFactory, nextSessionDelay: TimeInterval = 1,
                 retryBaseDelay: TimeInterval = 1) {
        self.factory = factory
        self.nextSessionDelay = nextSessionDelay.isFinite ? max(0, nextSessionDelay) : 1
        self.retryBaseDelay = retryBaseDelay.isFinite ? max(0.01, retryBaseDelay) : 1
    }

    deinit {
        reconciliation?.cancel(); wake?.cancel()
        for slot in slots.values {
            Task { @MainActor in
                guard !slot.stopping else { return }
                slot.startTask?.cancel(); slot.eventTask?.cancel()
                await slot.session.stop()
            }
        }
    }

    /// Connection failures affect engagement only. Transient startup failures retry while current.
    public func connectionState(for item: HMMediaItem) -> ConnectionState { states[item.id] ?? .idle }
    /// Returns chat, message reaction and voting support for HotMic items.
    /// Item fire membership and comment paging are added only when the session backend provides them.
    /// Main actor.
    public func capabilities(for item: HMMediaItem) -> HMEngagementCapabilities {
        guard streamID(for: item) != nil else { return .readOnly }
        var capabilities: HMEngagementCapabilities = [.sendChat, .reactToMessage, .vote]
        capabilities.formUnion(factory.itemEngagement.intersection([.toggleReaction, .loadComments]))
        return capabilities
    }
    /// Returns an inert timeline; never opens a session. Main actor.
    public func timeline(for item: HMMediaItem) -> any HMStreamTimeline { store(for: item) }
    /// Returns polls currently mapped onto the VOD timeline. Main actor.
    public func polls(for item: HMMediaItem) -> [HMPoll] { Array(store(for: item).polls.values) }
    /// Attaches engagement weakly and applies prepared updates. Main actor.
    public func engagementDidLoad(_ engagement: HMEngagement) {
        let timeline = store(for: engagement.item)
        timeline.engagement = engagement
        for poll in timeline.polls.values { engagement.upsertPoll(poll) }
        for chat in timeline.messages.values { engagement.updateReactions(chat.counts, forMessage: chat.id) }
        for (emoji, summary) in timeline.itemReactions { engagement.updateReactionSummary(summary, for: emoji) }
        if let count = timeline.commentCount { engagement.updateCommentCount(count) }
        for id in timeline.liveCommentOrder {
            if let event = timeline.liveComments[id] { engagement.upsertComment(event) }
        }
        // Deletions can arrive during next-item preparation, before the UI asks for engagement.
        for event in timeline.pendingDeletions { applyDeletion(event, to: timeline) }
        timeline.pendingDeletions.removeAll()
    }
    /// Prepares next after the current-item dwell, within the two-session budget. Main actor.
    public func willBecomeNext(_ item: HMMediaItem) { next = item; scheduleReconciliation() }
    /// Promotes a prepared session or opens current. Main actor.
    public func didBecomeCurrent(_ item: HMMediaItem) {
        if current?.id != item.id || current.flatMap({ streamID(for: $0) }) != streamID(for: item) {
            currentSince = .now
        }
        current = item
        if next?.id == item.id { next = nil }
        scheduleReconciliation()
    }
    /// Stops an item after it leaves current and next. Main actor.
    public func didLeave(_ item: HMMediaItem) {
        if current?.id == item.id { current = nil; currentSince = nil }
        if next?.id == item.id { next = nil }
        failed.remove(item.id); retryAt[item.id] = nil; attempts[item.id] = nil
        scheduleReconciliation()
    }

    /// Sends chat through the active session at the viewer’s media position. Main actor.
    public func sendChat(_ text: String, for item: HMMediaItem) async throws {
        let timeline = store(for: item)
        let message = HMChatMessage(id: UUID().uuidString, author: "You", text: text,
                                    offset: timeline.engagement?.currentMediaTime ?? 0)
        if let event = try await sendChat(message, for: item) { timeline.engagement?.receive(event) }
    }
    /// Sends chat through the active session at the viewer’s media position. Main actor.
    public func sendChat(_ message: HMChatMessage, for item: HMMediaItem) async throws -> HMTimelineEvent? {
        let slot = try activeSlot(for: item)
        let confirmed = try await slot.session.sendChat(message.text)
        // Keep a confirmed send at the viewer's playback position, not today's wall time on an old VOD.
        slot.timeline.ownOffsets[confirmed.id] = message.offset.isFinite ? max(0, message.offset) : 0
        slot.timeline.remember(confirmed)
        guard let event = slot.timeline.event(confirmed) else { return nil }
        slot.timeline.append(event)
        return event
    }
    /// Adds one of 👍 / 🔥 / 😆 / 😡 / 😢 to a message. Main actor.
    public func react(_ emoji: String, toMessage messageID: String, for item: HMMediaItem) async throws {
        guard let type = Self.types[emoji] else { throw HMInteractionError.unsupportedAction }
        let slot = try activeSlot(for: item)
        let reaction = try await slot.session.addReaction(type, to: messageID)
        applyReaction(reaction, added: true, to: slot)
    }
    /// Sets item reaction membership and returns authoritative totals. Main actor.
    /// HotMicCore 1.0.2 cannot serve this; only a session factory that advertises `.toggleReaction` can.
    public func setReaction(_ emoji: String, isReacted: Bool, for item: HMMediaItem) async throws -> HMItemReactionSummary {
        guard factory.itemEngagement.contains(.toggleReaction) else { throw HMInteractionError.unsupportedAction }
        let slot = try activeSlot(for: item)
        let reaction = try await slot.session.setItemReaction(emoji, isReacted: isReacted)
        let summary = HMItemReactionSummary(count: reaction.count, reactedByViewer: reaction.reactedByViewer)
        slot.timeline.itemReactions[reaction.emoji] = summary
        slot.timeline.engagement?.updateReactionSummary(summary, for: reaction.emoji)
        return summary
    }
    /// Loads an item comment page without placing those comments on the VOD timeline. Main actor.
    /// HotMicCore 1.0.2 cannot page chat history; only a session factory that advertises `.loadComments` can.
    public func comments(for item: HMMediaItem, before cursor: String?) async throws -> HMCommentPage {
        guard factory.itemEngagement.contains(.loadComments) else { throw HMInteractionError.unsupportedAction }
        let slot = try activeSlot(for: item)
        let page = try await slot.session.comments(before: cursor)
        if let totalCount = page.totalCount {
            let count = max(0, totalCount)
            slot.timeline.commentCount = count
            slot.timeline.engagement?.updateCommentCount(count)
        }
        return HMCommentPage(comments: page.comments.map(commentEvent), olderCursor: page.olderCursor, totalCount: page.totalCount)
    }
    /// Submits a poll option; Core poll updates reconcile the result. Main actor.
    public func vote(pollID: String, optionID: String, for item: HMMediaItem) async throws {
        let slot = try activeSlot(for: item)
        try await slot.session.vote(pollID: pollID, optionID: optionID)
        // Core emits pollUpdated with myAnswer; the engagement owns optimistic vote/rollback.
    }

    private static let types = ["👍": "like", "🔥": "fire", "😆": "laugh", "😡": "anger", "😢": "sadness"]
    private static func emoji(_ type: String) -> String? { types.first { $0.value == type }?.key }

    private func streamID(for item: HMMediaItem) -> String? {
        if case .reference(let namespace, let id) = item.source { return namespace == "hotmic" ? id : nil }
        // HotMicPlaylistSource keeps direct URLs, carrying their originating reference explicitly.
        if item.metadata["hotmic.namespace"] == "hotmic" { return item.metadata["hotmic.streamID"] }
        if let original = [current, next].compactMap({ $0 }).first(where: { $0.id == item.id }),
           case .reference("hotmic", let id) = original.source { return id }
        return nil
    }
    private func store(for item: HMMediaItem) -> HotMicTimeline {
        let streamID = streamID(for: item)
        if let existing = timelines[item.id]?.value, existing.streamID == streamID {
            existing.supplyDuration(item.durationHint)
            return existing
        }
        timelines = timelines.filter { $0.value.value != nil }
        let timeline = HotMicTimeline(streamID: streamID, duration: item.durationHint ?? 0)
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
            self?.reconciliation = nil
            self?.reconcile()
        }
    }
    private func reconcile() {
        wake?.cancel(); wake = nil
        let now = ContinuousClock.now
        let nextDue = currentSince?.advanced(by: .seconds(nextSessionDelay))
        let prepareNext = nextSessionDelay == 0 || nextDue.map { now >= $0 } == true
        let candidates = [current, prepareNext ? next : nil].compactMap { $0 }
        let wanted = candidates.filter { item in
            guard streamID(for: item) != nil, !failed.contains(item.id) else { return false }
            guard let due = retryAt[item.id] else { return true }
            return current?.id == item.id && now >= due
        }
        for (id, slot) in slots where !slot.stopping {
            // A prepared next survives promotion and role swaps; a changed next is obsolete.
            let retained = [current, next].compactMap { $0 }.contains {
                $0.id == id && streamID(for: $0) == slot.timeline.streamID
            }
            if !retained || failed.contains(id) || retryAt[id] != nil {
                stop(slot, id: id)
            }
        }
        for item in wanted where slots[item.id] == nil {
            // Stopping sessions still occupy capacity. Every stop runs independently.
            guard slots.count < 2 else { break }
            let timeline = store(for: item)
            guard let streamID = timeline.streamID else { continue }
            retryAt[item.id] = nil
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
                    guard let self, let slot, !Task.isCancelled, self.slots[item.id] === slot, !slot.stopping, !slot.failureHandled else { return }
                    slot.userID = snapshot.userID
                    slot.timeline.retime(liveDate: snapshot.liveDate, duration: snapshot.duration)
                    self.receive(snapshot.messages, in: slot)
                    snapshot.polls.forEach { self.upsert($0, in: slot) }
                    slot.ready = true
                    self.attempts[item.id] = nil
                    self.applyItemState(snapshot.itemReactions, commentCount: snapshot.commentCount, to: slot.timeline)
                    let queued = slot.queued; slot.queued.removeAll()
                    for event in queued { self.consume(event, itemID: item.id, slot: slot) }
                } catch {
                    guard let self, let slot, !slot.stopping, self.slots[item.id] === slot else { return }
                    self.fail(item.id, slot: slot, error: error)
                }
            }
        }
        var deadlines: [ContinuousClock.Instant] = []
        if next != nil, !prepareNext, let nextDue { deadlines.append(nextDue) }
        if let current, let due = retryAt[current.id], due > now { deadlines.append(due) }
        if let due = deadlines.min() {
            let delay = now.duration(to: due)
            wake = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: delay) } catch { return }
                self?.scheduleReconciliation()
            }
        }
        timelines = timelines.filter { $0.value.value != nil }
        let retained = Set([current?.id, next?.id].compactMap { $0 }).union(slots.keys)
        states = states.filter { retained.contains($0.key) }
    }
    private func stop(_ slot: Slot, id: String) {
        slot.stopping = true; slot.startTask?.cancel(); slot.eventTask?.cancel()
        slot.stopTask = Task { @MainActor [weak self] in
            await slot.session.stop()
            guard let self, self.slots[id] === slot else { return }
            self.slots[id] = nil
            if self.current?.id != id && self.next?.id != id { self.states[id] = nil }
            self.scheduleReconciliation()
        }
    }
    private func fail(_ id: String, slot: Slot, error: Error) {
        guard !slot.failureHandled else { return }
        slot.failureHandled = true; slot.ready = false; states[id] = .failed
        if Self.isTransient(error) {
            let attempt = attempts[id, default: 0]
            attempts[id] = min(attempt + 1, 6)
            retryAt[id] = .now.advanced(by: .seconds(min(30, retryBaseDelay * pow(2, Double(attempt)))))
        } else { failed.insert(id) }
        scheduleReconciliation()
    }
    private static func isTransient(_ error: Error) -> Bool {
        if let error = error as? HotMicError {
            switch error {
            case .transport: return true
            case .server(let code, _): return code == 429 || (500...599).contains(code)
            default: return false
            }
        }
        if let error = error as? URLError {
            return [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                    .dnsLookupFailed, .notConnectedToInternet, .internationalRoamingOff,
                    .callIsActive, .dataNotAllowed].contains(error.code)
        }
        return false
    }
    private func consume(_ event: _HotMicSessionEvent, itemID: String, slot: Slot) {
        guard !slot.failureHandled else { return }
        switch event {
        case .connection(let state): states[itemID] = state; return
        case .failed(let error): fail(itemID, slot: slot, error: error); return
        case .deleted, .ended:
            failed.insert(itemID); states[itemID] = .disconnected; scheduleReconciliation(); return
        default: break
        }
        guard slot.ready else { slot.queued.append(event); return }
        switch event {
        case .chat(let messages, let reactions):
            receive(messages, in: slot)
            reactions.forEach { applyReaction($0, added: true, to: slot) }
        case .messageDeleted(let id):
            slot.timeline.remove(id)
            deletion(event, timeline: slot.timeline)
        case .reactionDeleted(let reaction): applyReaction(reaction, added: false, to: slot)
        case .poll(let poll): upsert(poll, in: slot)
        case .itemReaction(let reaction): applyItemState([reaction], commentCount: nil, to: slot.timeline)
        case .liveComment(let chat, let totalCount):
            let event = commentEvent(chat)
            slot.timeline.rememberLiveComment(event)
            slot.timeline.engagement?.upsertComment(event)
            applyItemState([], commentCount: totalCount, to: slot.timeline)
        case .pollDeleted(let id):
            slot.timeline.removePoll(id)
            deletion(event, timeline: slot.timeline)
        case .stream(let date, let duration):
            slot.timeline.retime(liveDate: date, duration: duration)
        default: break
        }
    }
    private func commentEvent(_ chat: _HotMicChat) -> HMTimelineEvent {
        HMTimelineEvent(id: chat.id, offset: 0, kind: .chat, author: chat.author, text: chat.text,
                        avatarURL: chat.avatar, wallTime: chat.createdAt, reactions: chat.counts.filter { $0.value > 0 })
    }
    private func applyItemState(_ reactions: [_HotMicItemReaction], commentCount: Int?, to timeline: HotMicTimeline) {
        for reaction in reactions {
            let summary = HMItemReactionSummary(count: reaction.count, reactedByViewer: reaction.reactedByViewer)
            timeline.itemReactions[reaction.emoji] = summary
            timeline.engagement?.updateReactionSummary(summary, for: reaction.emoji)
        }
        if let commentCount {
            let count = max(0, commentCount)
            timeline.commentCount = count
            timeline.engagement?.updateCommentCount(count)
        }
    }
    private func receive(_ messages: [_HotMicChat], in slot: Slot) {
        let mapped = messages.compactMap { chat -> (_HotMicChat, HMTimelineEvent)? in
            slot.timeline.remember(chat)
            guard let event = slot.timeline.event(chat) else { return nil }
            return (chat, event)
        }
        // One sort/waveform rebuild, with the player's moderation guard before each append.
        let events = mapped.filter { slot.timeline.messages[$0.0.id] != nil }.map { $0.1 }
        if let engagement = slot.timeline.engagement {
            slot.timeline.append(contentsOf: events) { engagement.receive($0) }
            for (chat, _) in mapped { engagement.updateReactions(chat.counts, forMessage: chat.id) }
        } else { slot.timeline.append(contentsOf: events) }
    }
    private func upsert(_ poll: _HotMicPoll, in slot: Slot) {
        slot.timeline.remember(poll)
    }
    private func applyReaction(_ reaction: _HotMicMessageReaction, added: Bool, to slot: Slot) {
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
            timeline.engagement?.updateReactions(chat.counts, forMessage: chat.id)
        }
    }
    private func deletion(_ event: _HotMicSessionEvent, timeline: HotMicTimeline) {
        if timeline.engagement == nil { timeline.pendingDeletions.append(event) }
        else { applyDeletion(event, to: timeline) }
    }
    private func applyDeletion(_ event: _HotMicSessionEvent, to timeline: HotMicTimeline) {
        switch event {
        case .messageDeleted(let id): timeline.engagement?.removeMessage(id: id)
        case .pollDeleted(let id): timeline.engagement?.removePoll(id: id)
        default: break
        }
    }
}

@MainActor private final class Slot {
    let session: any _HotMicSession
    let timeline: HotMicTimeline
    var startTask: Task<Void, Never>?
    var eventTask: Task<Void, Never>?
    var stopTask: Task<Void, Never>?
    var failureHandled = false
    var queued: [_HotMicSessionEvent] = []
    var ready = false
    var stopping = false
    var userID = ""
    var reactionState: [ReactionKey: Bool] = [:]
    init(session: any _HotMicSession, timeline: HotMicTimeline) { self.session = session; self.timeline = timeline }
}
private struct ReactionKey: Hashable { let message: String; let user: String; let type: String }
@MainActor private final class WeakTimeline {
    weak var value: HotMicTimeline?
    init(_ value: HotMicTimeline) { self.value = value }
}
