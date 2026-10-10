import XCTest
import HotMicPlayer
import HotMicCore
@testable import HotMicPlayerConnect
@testable import HotMicPlayerConnectTesting

@MainActor private final class Sessions: HotMicSessionFactory {
    var sessions: [String: [Session]] = [:]
    var live: Set<ObjectIdentifier> = []
    var maximum = 0
    var stopGate: CheckedContinuation<Void, Never>?
    var holdStop = false
    var failStart = false
    var failures: [String: [HotMicError]] = [:]
    var missingOrigins: Set<String> = []
    var missingDurations: Set<String> = []
    var heldStopIDs: Set<String> = []
    var stopGates: [String: CheckedContinuation<Void, Never>] = [:]
    var holdStarts: Set<String> = []
    var itemEngagement: HMEngagementCapabilities = []
    var fireCount = 4
    var fireReacted = false
    var reactionEmojiOverride: String?
    let origin = Date(timeIntervalSince1970: 1000)
    func makeSession(streamID: String) -> any HotMicSession {
        let session = Session(id: streamID, owner: self)
        sessions[streamID, default: []].append(session)
        return session
    }
    func latest(_ id: String) -> Session { sessions[id]!.last! }
}

@MainActor private final class Session: HotMicSession {
    let id: String
    unowned let owner: Sessions
    let events: AsyncStream<HotMicSessionEvent>
    let continuation: AsyncStream<HotMicSessionEvent>.Continuation
    var stopped = false
    var sends = 0
    var votes: [String] = []
    var startGate: CheckedContinuation<Void, Never>?
    init(id: String, owner: Sessions) {
        self.id = id; self.owner = owner
        let pair = AsyncStream<HotMicSessionEvent>.makeStream()
        events = pair.stream; continuation = pair.continuation
    }
    func start() async throws -> HotMicSessionSnapshot {
        owner.live.insert(ObjectIdentifier(self)); owner.maximum = max(owner.maximum, owner.live.count)
        if owner.failStart { throw URLError(.notConnectedToInternet) }
        if let error = owner.failures[id]?.first {
            owner.failures[id]?.removeFirst()
            continuation.yield(.failed(error)) // Core also throws this error from start.
            throw error
        }
        continuation.yield(.connection(.connected))
        if owner.holdStarts.contains(id) { await withCheckedContinuation { startGate = $0 } }
        return HotMicSessionSnapshot(liveDate: owner.missingOrigins.contains(id) ? nil : owner.origin, duration: owner.missingDurations.contains(id) ? nil : 42, userID: "viewer",
                                   messages: [chat("history", at: 5, counts: ["👍": 2])], polls: [poll()],
                                   itemReactions: owner.itemEngagement.contains(.toggleReaction) ? [.init(emoji: "🔥", count: owner.fireCount, reactedByViewer: owner.fireReacted)] : [],
                                   commentCount: owner.itemEngagement.contains(.loadComments) ? 2 : nil)
    }
    func stop() async {
        guard !stopped else { return }
        if owner.holdStop { await withCheckedContinuation { owner.stopGate = $0 } }
        if owner.heldStopIDs.contains(id) { await withCheckedContinuation { owner.stopGates[id] = $0 } }
        stopped = true; owner.live.remove(ObjectIdentifier(self)); continuation.finish()
    }
    func sendChat(_ text: String) async throws -> HotMicChat {
        sends += 1
        return HotMicChat(id: "server-\(sends)", author: "Confirmed viewer", text: text,
                        createdAt: owner.origin.addingTimeInterval(1000))
    }
    func addReaction(_ type: String, to messageID: String) async throws -> HotMicMessageReaction {
        .init(messageID: messageID, userID: "viewer", type: type)
    }
    func setItemReaction(_ emoji: String, isReacted: Bool) async throws -> HotMicItemReaction {
        if let reactionEmojiOverride = owner.reactionEmojiOverride {
            return .init(emoji: reactionEmojiOverride, count: owner.fireCount, reactedByViewer: isReacted)
        }
        guard emoji == "🔥" else { throw HMInteractionError.unsupportedAction }
        if owner.fireReacted != isReacted {
            owner.fireCount = max(0, owner.fireCount + (isReacted ? 1 : -1))
            owner.fireReacted = isReacted
        }
        return .init(emoji: "🔥", count: owner.fireCount, reactedByViewer: owner.fireReacted)
    }
    func comments(before cursor: String?) async throws -> HotMicCommentPage {
        if cursor == nil { return .init(comments: [chat("newer", at: 20)], olderCursor: "old", totalCount: 2) }
        if cursor == "old" { return .init(comments: [chat("older", at: 1)], olderCursor: nil, totalCount: nil) }
        throw HMInteractionError.unsupportedAction
    }
    func vote(pollID: String, optionID: String) async throws {
        votes.append(optionID); continuation.yield(.poll(poll(vote: optionID)))
    }
    func chat(_ id: String, at offset: Double, counts: [String: Int] = [:]) -> HotMicChat {
        .init(id: id, author: "History", text: id, createdAt: owner.origin.addingTimeInterval(offset), counts: counts)
    }
    func poll(vote: String? = nil) -> HotMicFixturePoll {
        .init(id: "poll", question: "Replay?", createdAt: owner.origin.addingTimeInterval(2), viewerVote: vote,
              options: [.init(id: "yes", text: "Yes", votes: vote == nil ? 2 : 3)])
    }
}

@MainActor final class HotMicInteractionTests: XCTestCase {
    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for session/state", file: file, line: line)
    }
    private func leave(_ source: HotMicInteractionSource, _ factory: Sessions, _ items: [HMMediaItem]) async {
        items.forEach { source.didLeave($0) }
        await waitUntil { factory.live.isEmpty }
    }

    func testTwoSessionsPromotionBackwardSwapAndStopBarrier() async {
        let factory = Sessions()
        let source = HotMicInteractionSource(factory: factory, nextSessionDelay: 0)
        // Timeline construction is inert, even for HotMic references.
        _ = source.timeline(for: .hotmicStream("unused"))
        let interactions = HotMicInteractionSource(factory: factory, nextSessionDelay: 0)
        let a = HMMediaItem.hotmicStream("a"), b = HMMediaItem.hotmicStream("b"), c = HMMediaItem.hotmicStream("c")
        interactions.didBecomeCurrent(a); interactions.willBecomeNext(b)
        await waitUntil { factory.live.count == 2 }
        let firstB = factory.latest("b")
        factory.holdStop = true
        interactions.didLeave(a); interactions.didBecomeCurrent(b); interactions.willBecomeNext(c)
        await waitUntil { factory.stopGate != nil }
        XCTAssertNil(factory.sessions["c"], "Replacement must wait for async stop, not merely cancel")
        XCTAssertEqual(factory.live.count, 2)
        factory.holdStop = false; factory.stopGate?.resume(); factory.stopGate = nil
        await waitUntil { factory.sessions["c"] != nil && factory.live.count == 2 }
        XCTAssertTrue(factory.latest("b") === firstB, "Promotion must reuse the next session")
        // Backward swipe: B becomes next after A becomes current in the same hook burst.
        interactions.didLeave(c); interactions.didBecomeCurrent(a); interactions.willBecomeNext(b)
        await waitUntil { factory.sessions["a"]?.count == 2 && factory.latest("c").stopped }
        XCTAssertTrue(factory.latest("b") === firstB)
        XCTAssertEqual(factory.maximum, 2)
        await leave(interactions, factory, [a, b])
        XCTAssertTrue(firstB.stopped)
        // Reusing a playlist ID must not inherit an old stream/namespace from a weak cache.
        let retained = interactions.timeline(for: a)
        let replacement = HMMediaItem.reference("hotmic", id: "other-stream", playlistID: a.id)
        interactions.didBecomeCurrent(replacement)
        await waitUntil { factory.sessions["other-stream"] != nil && interactions.connectionState(for: replacement) == .connected }
        XCTAssertFalse(interactions.timeline(for: replacement) === retained)
        let foreign = HMMediaItem(id: a.id, url: URL(string: "https://example.com/foreign.mp4")!)
        interactions.didLeave(replacement); interactions.didBecomeCurrent(foreign)
        await waitUntil { factory.live.isEmpty }
        XCTAssertEqual(interactions.capabilities(for: foreign), .readOnly)
        XCTAssertTrue(interactions.timeline(for: foreign).events(in: 0...42).isEmpty)
        interactions.didLeave(foreign)
    }

    func testSnapshotBatchesActionsDeletionAndEchoReconciliation() async throws {
        let factory = Sessions(), item = HMMediaItem.hotmicStream("one")
        let source = HotMicInteractionSource(factory: factory, nextSessionDelay: 0)
        let timeline = source.timeline(for: item)
        let engagement = HMEngagement(item: item, timeline: timeline, source: source, mediaClock: { 7 })
        source.engagementDidLoad(engagement); source.didBecomeCurrent(item)
        await waitUntil { engagement.polls.count == 1 && source.connectionState(for: item) == .connected }
        let session = factory.latest("one")
        XCTAssertEqual(engagement.messages(near: 7).first?.reactions["👍"], 2)
        XCTAssertEqual(engagement.polls.first?.opensAt, 2)
        try await engagement.sendChat("Hello", at: 7)
        let own = engagement.messages(near: 7).first { $0.isOwn }!
        XCTAssertEqual(own.id, "server-1"); XCTAssertEqual(own.author, "Confirmed viewer"); XCTAssertEqual(own.offset, 7)
        session.continuation.yield(.chat(messages: [session.chat("server-1", at: 999)], reactions: []))
        session.continuation.yield(.connection(.reconnecting(attempt: 1)))
        await waitUntil { source.connectionState(for: item) == .reconnecting(attempt: 1) }
        XCTAssertTrue(engagement.messages(near: 7).contains { $0.id == "server-1" && $0.offset == 7 })
        XCTAssertEqual(engagement.messages(near: 42, lookback: 42).filter { $0.id == "server-1" }.count, 1)
        try await engagement.react("👍", toMessage: "history")
        XCTAssertEqual(engagement.messages(near: 7).first { $0.id == "history" }?.reactions["👍"], 3)
        let removal = HotMicMessageReaction(messageID: "history", userID: "viewer", type: "like")
        session.continuation.yield(.reactionDeleted(removal)); session.continuation.yield(.reactionDeleted(removal))
        await waitUntil { engagement.messages(near: 7).first { $0.id == "history" }?.reactions["👍"] == 2 }
        XCTAssertEqual(engagement.messages(near: 7).first { $0.id == "history" }?.ownReactions, [])
        try await engagement.vote(pollID: "poll", optionID: "yes")
        await waitUntil { engagement.polls.first?.viewerVote == "yes" }
        XCTAssertEqual(session.votes, ["yes"])
        session.continuation.yield(.chat(messages: [session.chat("batch", at: 6)], reactions: []))
        await waitUntil { engagement.messages(near: 7).contains { $0.id == "batch" } }
        session.continuation.yield(.messageDeleted("batch")); session.continuation.yield(.messageDeleted("server-1"))
        session.continuation.yield(.pollDeleted("poll"))
        await waitUntil { engagement.polls.isEmpty && !engagement.messages(near: 7).contains { ["batch", "server-1"].contains($0.id) } }
        let beforeEcho = timeline.density.map(\.eventCount)
        session.continuation.yield(.chat(messages: [session.chat("batch", at: 6), session.chat("server-1", at: 7)], reactions: []))
        session.continuation.yield(.poll(session.poll()))
        session.continuation.yield(.connection(.reconnecting(attempt: 2)))
        await waitUntil { source.connectionState(for: item) == .reconnecting(attempt: 2) }
        XCTAssertTrue(engagement.polls.isEmpty)
        XCTAssertEqual(timeline.density.map(\.eventCount), beforeEcho, "Deleted echoes must not restore raw waveform contributions")
        XCTAssertFalse(timeline.events(in: 0...42).contains { ["batch", "server-1"].contains($0.id) })
        XCTAssertFalse(engagement.messages(near: 7).contains { ["batch", "server-1"].contains($0.id) })
        session.continuation.yield(.connection(.connected))
        await waitUntil { source.connectionState(for: item) == .connected }
        XCTAssertEqual(factory.sessions["one"]?.count, 1, "Core reconnects in the existing session")
        await leave(source, factory, [item])
    }

    func testStartupBufferAndCancelledStartCannotOverwriteNewWindow() async {
        let factory = Sessions()
        let interactions = HotMicInteractionSource(factory: factory, nextSessionDelay: 0)
        let a = HMMediaItem.hotmicStream("a"), b = HMMediaItem.hotmicStream("b")
        factory.holdStarts.insert("a")
        interactions.didBecomeCurrent(a)
        await waitUntil { factory.sessions["a"]?.last?.startGate != nil }
        let starting = factory.latest("a")
        starting.continuation.yield(.messageDeleted("history"))
        starting.continuation.yield(.pollDeleted("poll"))
        starting.startGate?.resume(); starting.startGate = nil
        let timeline = interactions.timeline(for: a)
        let engagement = HMEngagement(item: a, timeline: timeline, source: interactions)
        interactions.engagementDidLoad(engagement)
        await waitUntil { timeline.duration == 42 && (timeline as? HotMicTimeline)?.messages["history"] == nil && engagement.polls.isEmpty }
        // A connection barrier proves buffered content has been processed, not just initially empty.
        starting.continuation.yield(.connection(.reconnecting(attempt: 9)))
        await waitUntil { interactions.connectionState(for: a) == .reconnecting(attempt: 9) }
        XCTAssertTrue(engagement.messages(near: 42, lookback: 42).isEmpty)
        XCTAssertTrue(engagement.polls.isEmpty)
        await leave(interactions, factory, [a])
        interactions.didBecomeCurrent(a)
        await waitUntil { factory.latest("a").startGate != nil }
        let obsolete = factory.latest("a")
        interactions.didLeave(a); interactions.didBecomeCurrent(b)
        await waitUntil { obsolete.stopped && interactions.connectionState(for: b) == .connected }
        obsolete.startGate?.resume(); obsolete.startGate = nil
        obsolete.continuation.yield(.connection(.connected))
        await leave(interactions, factory, [b])
        XCTAssertEqual(interactions.connectionState(for: a), .idle)
        XCTAssertLessThanOrEqual(factory.maximum, 2)
    }

    func testMediaOffsetsDropOutsideWindowAndUnsupportedItemsStayEmpty() async throws {
        let factory = Sessions(), source = HotMicInteractionSource(factory: Sessions())
        let timeline = HotMicTimeline(streamID: "one", duration: 42, liveDate: factory.origin)
        XCTAssertNil(timeline.offset(factory.origin.addingTimeInterval(-10)))
        XCTAssertEqual(timeline.offset(factory.origin.addingTimeInterval(12)), 12)
        XCTAssertNil(timeline.offset(factory.origin.addingTimeInterval(100)))
        timeline.retime(liveDate: nil, duration: nil)
        XCTAssertNil(timeline.offset(factory.origin), "Missing origin means no replay timing")
        for item in [HMMediaItem.reference("partner", id: "one"), HMMediaItem(id: "hotmic:one", url: URL(string: "https://example.com/one.mp4")!)] {
            XCTAssertEqual(source.capabilities(for: item), .readOnly)
            source.didBecomeCurrent(item)
            XCTAssertTrue(source.timeline(for: item).events(in: 0...100).isEmpty)
            do { _ = try await source.sendChat(HMChatMessage(id: "x", author: "You", text: "Hi", offset: 0), for: item); XCTFail("Unsupported action") }
            catch { XCTAssertTrue(error is HMInteractionError) }
            source.didLeave(item)
        }
        let hotmic = HMMediaItem.hotmicStream("one")
        XCTAssertEqual(source.capabilities(for: hotmic), [.sendChat, .reactToMessage, .vote])
        XCTAssertFalse(source.capabilities(for: hotmic).contains(.reactToStream))
    }

    func testPreparationDeletionsBeforeEngagementAndFailureReentry() async {
        let factory = Sessions()
        let interactions = HotMicInteractionSource(factory: factory, nextSessionDelay: 0), item = HMMediaItem.hotmicStream("next")
        interactions.willBecomeNext(item)
        await waitUntil { factory.sessions["next"] != nil && interactions.connectionState(for: item) == .connected }
        factory.latest("next").continuation.yield(.messageDeleted("history"))
        factory.latest("next").continuation.yield(.pollDeleted("poll"))
        factory.latest("next").continuation.yield(.connection(.reconnecting(attempt: 3)))
        await waitUntil { interactions.connectionState(for: item) == .reconnecting(attempt: 3) }
        let engagement = HMEngagement(item: item, timeline: interactions.timeline(for: item), source: interactions)
        interactions.engagementDidLoad(engagement)
        XCTAssertTrue(engagement.messages(near: 42, lookback: 42).isEmpty); XCTAssertTrue(engagement.polls.isEmpty)
        await leave(interactions, factory, [item])
        factory.failStart = true
        interactions.didBecomeCurrent(item)
        await waitUntil { interactions.connectionState(for: item) == .failed && factory.live.isEmpty }
        interactions.didLeave(item)
        factory.failStart = false
        interactions.didBecomeCurrent(item)
        await waitUntil { factory.live.count == 1 && interactions.connectionState(for: item) == .connected }
        XCTAssertEqual(factory.sessions["next"]?.count, 3)
        await leave(interactions, factory, [item])
    }

    func testBatchDropsOutsideWindowAndMissingOriginWithoutBoundarySpikes() async throws {
        let factory = Sessions(), item = HMMediaItem.hotmicStream("batch")
        let source = HotMicInteractionSource(factory: factory)
        let timeline = source.timeline(for: item) as! HotMicTimeline
        let engagement = HMEngagement(item: item, timeline: timeline, source: source)
        source.engagementDidLoad(engagement); source.didBecomeCurrent(item)
        await waitUntil { timeline.messages.count == 1 }
        let session = factory.latest("batch"), before = timeline.rebuildCount
        let batch = (0..<50).map { session.chat("batch-\($0)", at: 1 + Double($0) / 50) }
        session.continuation.yield(.chat(messages: batch + [session.chat("pre", at: -1), session.chat("post", at: 43)], reactions: []))
        for offset in [-1.0, 43.0] {
            session.continuation.yield(.poll(.init(id: "outside-\(offset)", question: "Outside", createdAt: factory.origin.addingTimeInterval(offset), options: [])))
        }
        session.continuation.yield(.connection(.reconnecting(attempt: 50)))
        await waitUntil { source.connectionState(for: item) == .reconnecting(attempt: 50) }
        XCTAssertEqual(timeline.rebuildCount - before, 1, "One sort and waveform rebuild for a 50-message batch, including engagement.receive")
        XCTAssertEqual(timeline.events(in: 0...42).count, 51)
        XCTAssertEqual(engagement.messages(near: 42, lookback: 42, limit: 100).count, 51)
        XCTAssertEqual(engagement.polls.map(\.id), ["poll"])
        XCTAssertEqual(timeline.density.first?.eventCount, 0)
        XCTAssertEqual(timeline.density.last?.eventCount, 0)
        XCTAssertEqual(timeline.offset(factory.origin), 0)
        XCTAssertEqual(timeline.offset(factory.origin.addingTimeInterval(42)), 42)
        let after = timeline.rebuildCount
        session.continuation.yield(.stream(liveDate: factory.origin, duration: 42))
        session.continuation.yield(.connection(.connected))
        await waitUntil { source.connectionState(for: item) == .connected }
        XCTAssertEqual(timeline.rebuildCount, after, "Unchanged stream update must not re-receive history")
        await leave(source, factory, [item])

        let missing = HMMediaItem.hotmicStream("missing")
        factory.missingOrigins.insert("missing")
        let empty = HMEngagement(item: missing, timeline: source.timeline(for: missing), source: source)
        source.engagementDidLoad(empty); source.didBecomeCurrent(missing)
        await waitUntil { source.connectionState(for: missing) == .connected }
        XCTAssertTrue(empty.messages(near: 42, lookback: 42).isEmpty)
        XCTAssertTrue(empty.polls.isEmpty)
        XCTAssertTrue(empty.density.allSatisfy { $0.eventCount == 0 })
        try await empty.sendChat("Own send has a playback clock", at: 7)
        XCTAssertEqual(empty.messages(near: 7).first?.offset, 7)
        await leave(source, factory, [missing])

        // No snapshot duration or item hint: retain raw history, preserve sends, then recover.
        for path in ["stream-update", "resolved-item"] {
            factory.missingDurations.insert(path)
            let unknown = HMMediaItem.hotmicStream(path)
            let retained = source.timeline(for: unknown) as! HotMicTimeline
            let pending = HMEngagement(item: unknown, timeline: retained, source: source)
            source.engagementDidLoad(pending); source.didBecomeCurrent(unknown)
            await waitUntil { retained.messages["history"] != nil }
            XCTAssertEqual(retained.duration, 0)
            XCTAssertTrue(retained.events(in: 0...42).isEmpty)
            XCTAssertTrue(pending.polls.isEmpty)
            try await pending.sendChat("Before duration", at: 7)
            XCTAssertEqual(retained.events(in: 7...7).first?.offset, 7)
            let session = factory.latest(path)
            session.continuation.yield(.chat(messages: [session.chat("deleted-pending", at: 3), session.chat("outside", at: 43)], reactions: []))
            session.continuation.yield(.messageDeleted("deleted-pending"))
            session.continuation.yield(.connection(.reconnecting(attempt: 60)))
            await waitUntil { source.connectionState(for: unknown) == .reconnecting(attempt: 60) }
            if path == "stream-update" {
                session.continuation.yield(.stream(liveDate: factory.origin, duration: 42))
                await waitUntil { retained.duration == 42 }
            } else {
                let resolved = HMMediaItem(id: unknown.id, url: URL(string: "https://example.com/replay.mp4")!,
                                          durationHint: 42, metadata: unknown.metadata)
                let resolvedEngagement = HMEngagement(item: resolved, timeline: retained, source: source)
                source.engagementDidLoad(resolvedEngagement)
                XCTAssertEqual(retained.duration, 42)
                XCTAssertTrue(source.timeline(for: resolved) === retained)
                // Reattach the query owner used below; it now sees the same recovered mapping.
                source.engagementDidLoad(pending)
            }
            XCTAssertTrue(pending.messages(near: 42, lookback: 42, limit: 100).contains { $0.id == "history" && $0.offset == 5 })
            XCTAssertTrue(retained.events(in: 0...42).contains { $0.id == "server-1" && $0.offset == 7 })
            XCTAssertFalse(retained.events(in: 0...42).contains { ["outside", "deleted-pending"].contains($0.id) })
            XCTAssertEqual(pending.polls.first?.opensAt, 2)
            await leave(source, factory, [unknown])
        }
        let bounded = HotMicTimeline(streamID: "bounded", duration: 0, liveDate: factory.origin)
        for index in 0..<(HotMicTimeline.messageCapacity + 10) {
            bounded.remember(.init(id: "raw-\(index)", author: "Replay", text: "History", createdAt: factory.origin.addingTimeInterval(5)))
        }
        XCTAssertEqual(bounded.messages.count, HotMicTimeline.messageCapacity)
        bounded.retime(liveDate: factory.origin, duration: 42)
        XCTAssertEqual(bounded.events(in: 0...42).count, HotMicTimeline.messageCapacity)
        XCTAssertFalse(bounded.events(in: 0...42).contains { $0.id == "raw-0" })
    }

    func testNextDebounceAndConcurrentStopsPreserveCapacity() async {
        let factory = Sessions()
        let source = HotMicInteractionSource(factory: factory, nextSessionDelay: 0.15)
        let a = HMMediaItem.hotmicStream("a"), b = HMMediaItem.hotmicStream("b")
        source.didBecomeCurrent(a); source.willBecomeNext(b)
        await waitUntil { factory.sessions["a"] != nil }
        for index in 0..<5 {
            let item = HMMediaItem.hotmicStream("binge-\(index)")
            source.didLeave(index == 0 ? a : .hotmicStream("binge-\(index - 1)"))
            source.didBecomeCurrent(item); source.willBecomeNext(.hotmicStream("unused-next-\(index)"))
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(factory.sessions["b"])
        XCTAssertTrue(factory.sessions.keys.allSatisfy { !$0.hasPrefix("unused-next") })
        await waitUntil { factory.sessions["unused-next-4"] != nil }
        await leave(source, factory, [.hotmicStream("binge-4"), .hotmicStream("unused-next-4")])

        let immediate = HotMicInteractionSource(factory: factory, nextSessionDelay: 0)
        immediate.didBecomeCurrent(a); immediate.willBecomeNext(b)
        await waitUntil { factory.live.count == 2 }
        factory.heldStopIDs.insert("a")
        let c = HMMediaItem.hotmicStream("c"), d = HMMediaItem.hotmicStream("d")
        immediate.didLeave(a); immediate.didLeave(b)
        immediate.didBecomeCurrent(c); immediate.willBecomeNext(d)
        await waitUntil { factory.stopGates["a"] != nil && factory.sessions["c"] != nil }
        XCTAssertFalse(factory.latest("a").stopped)
        XCTAssertTrue(factory.latest("b").stopped)
        XCTAssertNil(factory.sessions["d"], "Stopping A plus current C still occupies both slots")
        XCTAssertEqual(factory.live.count, 2)
        factory.heldStopIDs.remove("a"); factory.stopGates.removeValue(forKey: "a")?.resume()
        await waitUntil { factory.sessions["d"] != nil }
        XCTAssertEqual(factory.maximum, 2)
        await leave(immediate, factory, [c, d])
    }

    func testTransientStartBackoffWhileCurrentAndRetryCancellation() async {
        let factory = Sessions(), item = HMMediaItem.hotmicStream("retry")
        factory.failures["retry"] = [.transport(description: "fake"), .server(statusCode: 503, message: nil)]
        let source = HotMicInteractionSource(factory: factory, retryBaseDelay: 0.05)
        source.didBecomeCurrent(item)
        await waitUntil { factory.sessions["retry"]?.count == 1 && factory.live.isEmpty }
        try? await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(factory.sessions["retry"]?.count, 1, "No immediate retry spin")
        await waitUntil { factory.sessions["retry"]?.count == 3 && source.connectionState(for: item) == .connected }
        XCTAssertTrue(factory.sessions["retry"]!.dropLast().allSatisfy(\.stopped))
        await leave(source, factory, [item])
        factory.failures["retry"] = [.transport(description: "fake")]
        source.didBecomeCurrent(item)
        await waitUntil { factory.sessions["retry"]?.count == 4 && factory.live.isEmpty }
        source.didLeave(item)
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(factory.sessions["retry"]?.count, 4, "Leaving cancels pending backoff")
        factory.failures["retry"] = [.unauthorized]
        source.didBecomeCurrent(item)
        await waitUntil { factory.sessions["retry"]?.count == 5 && factory.live.isEmpty }
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(factory.sessions["retry"]?.count, 5, "Credential failures must not retry")
        await leave(source, factory, [item])
        XCTAssertLessThanOrEqual(factory.maximum, 2)
    }

    func testItemMembershipAndCommentPagingStayOffTheReplayTimeline() async throws {
        let idle = Sessions()
        let unavailable = HotMicInteractionSource(factory: idle, nextSessionDelay: 0)
        let plain = HMMediaItem.hotmicStream("plain")
        XCTAssertFalse(unavailable.capabilities(for: plain).contains(.toggleReaction))
        XCTAssertFalse(unavailable.capabilities(for: plain).contains(.loadComments))
        do {
            _ = try await unavailable.setReaction("🔥", isReacted: true, for: plain)
            XCTFail("Item membership stays unsupported until the factory advertises it")
        } catch { XCTAssertTrue(error is HMInteractionError) }
        unavailable.didBecomeCurrent(plain)
        await waitUntil { idle.sessions["plain"] != nil && unavailable.connectionState(for: plain) == .connected }
        let idleSession = idle.latest("plain")
        idleSession.continuation.yield(.itemReaction(.init(emoji: "🔥", count: 9, reactedByViewer: true)))
        idleSession.continuation.yield(.liveComment(idleSession.chat("hidden", at: 4), totalCount: 4))
        idleSession.continuation.yield(.connection(.reconnecting(attempt: 1)))
        await waitUntil { unavailable.connectionState(for: plain) == .reconnecting(attempt: 1) }
        let hidden = HMEngagement(item: plain, timeline: unavailable.timeline(for: plain), source: unavailable)
        unavailable.engagementDidLoad(hidden)
        XCTAssertNil(hidden.reactionSummary(for: "🔥"))
        XCTAssertNil(hidden.commentCount)
        XCTAssertFalse(hidden.comments().contains { $0.id == "hidden" })
        await leave(unavailable, idle, [plain])

        let factory = Sessions()
        factory.itemEngagement = [.toggleReaction, .loadComments]
        let item = HMMediaItem.hotmicStream("social")
        let source = HotMicInteractionSource(factory: factory, nextSessionDelay: 0)
        XCTAssertTrue(source.capabilities(for: item).isSuperset(of: [.sendChat, .reactToMessage, .vote, .toggleReaction, .loadComments]))
        XCTAssertFalse(source.capabilities(for: item).contains(.reactToStream))
        let foreign = HMMediaItem(id: "foreign", url: URL(string: "https://example.com/foreign.mp4")!)
        XCTAssertEqual(source.capabilities(for: foreign), .readOnly)
        let timeline = source.timeline(for: item) as! HotMicTimeline
        let engagement = HMEngagement(item: item, timeline: timeline, source: source, mediaClock: { 7 })
        source.engagementDidLoad(engagement)
        source.didBecomeCurrent(item)
        await waitUntil { engagement.reactionSummary(for: "🔥")?.count == 4 && engagement.commentCount == 2 }
        let replay = timeline.events(in: 0...42).map(\.id)
        XCTAssertEqual(replay, ["history"])
        try await engagement.toggleReaction("🔥")
        let added = try XCTUnwrap(engagement.reactionSummary(for: "🔥"))
        XCTAssertEqual(added.count, 5)
        XCTAssertTrue(added.reactedByViewer)
        try await engagement.toggleReaction("🔥")
        let removed = try XCTUnwrap(engagement.reactionSummary(for: "🔥"))
        XCTAssertEqual(removed.count, 4)
        XCTAssertFalse(removed.reactedByViewer)
        try await engagement.loadComments()
        try await engagement.loadComments()
        XCTAssertEqual(engagement.comments().map(\.id), ["older", "newer"])
        XCTAssertEqual(engagement.commentCount, 2, "A page without a total keeps the known count")
        XCTAssertNil(engagement.olderCommentsCursor)
        XCTAssertEqual(timeline.events(in: 0...42).map(\.id), replay)
        XCTAssertFalse(timeline.messages.keys.contains("older"))
        let session = factory.latest("social")
        session.continuation.yield(.liveComment(session.chat("live", at: 30), totalCount: 3))
        await waitUntil { engagement.comments().contains { $0.id == "live" } && engagement.commentCount == 3 }
        XCTAssertEqual(timeline.events(in: 0...42).map(\.id), replay)
        XCTAssertNil(timeline.messages["live"])
        let again = HMEngagement(item: item, timeline: timeline, source: source, mediaClock: { 7 })
        source.engagementDidLoad(again)
        XCTAssertEqual(again.reactionSummary(for: "🔥")?.reactedByViewer, false)
        XCTAssertEqual(again.commentCount, 3)
        XCTAssertTrue(again.comments().contains { $0.id == "live" })
        XCTAssertFalse(again.comments().contains { $0.id == "newer" }, "Paged rows reload through comments(for:before:)")
        session.continuation.yield(.messageDeleted("live"))
        await waitUntil { !again.comments().contains { $0.id == "live" } }
        XCTAssertNil(timeline.liveComments["live"])
        let afterDeletion = HMEngagement(item: item, timeline: timeline, source: source, mediaClock: { 7 })
        source.engagementDidLoad(afterDeletion)
        XCTAssertFalse(afterDeletion.comments().contains { $0.id == "live" })
        factory.reactionEmojiOverride = "👍"
        do {
            _ = try await source.setReaction("🔥", isReacted: true, for: item)
            XCTFail("A summary for a different emoji must not be stored")
        } catch { XCTAssertTrue(error is HMInteractionError) }
        XCTAssertEqual(timeline.itemReactions["🔥"]?.count, 4)
        XCTAssertNil(timeline.itemReactions["👍"])
        await leave(source, factory, [item])
    }

}
