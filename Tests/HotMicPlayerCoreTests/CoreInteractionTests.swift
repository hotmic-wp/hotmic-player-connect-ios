import XCTest
import HotMicPlayer
@_spi(Testing) @testable import HotMicPlayerCore

@MainActor private final class Sessions: CoreSessionFactory {
    var sessions: [String: [Session]] = [:]
    var live: Set<ObjectIdentifier> = []
    var maximum = 0
    var stopGate: CheckedContinuation<Void, Never>?
    var holdStop = false
    var failStart = false
    var holdStarts: Set<String> = []
    let origin = Date(timeIntervalSince1970: 1000)
    func makeSession(streamID: String) -> any CoreSession {
        let session = Session(id: streamID, owner: self)
        sessions[streamID, default: []].append(session)
        return session
    }
    func latest(_ id: String) -> Session { sessions[id]!.last! }
}

@MainActor private final class Session: CoreSession {
    let id: String
    unowned let owner: Sessions
    let events: AsyncStream<CoreSessionEvent>
    let continuation: AsyncStream<CoreSessionEvent>.Continuation
    var stopped = false
    var sends = 0
    var votes: [String] = []
    var startGate: CheckedContinuation<Void, Never>?
    init(id: String, owner: Sessions) {
        self.id = id; self.owner = owner
        let pair = AsyncStream<CoreSessionEvent>.makeStream()
        events = pair.stream; continuation = pair.continuation
    }
    func start() async throws -> CoreSessionSnapshot {
        owner.live.insert(ObjectIdentifier(self)); owner.maximum = max(owner.maximum, owner.live.count)
        if owner.failStart { throw URLError(.notConnectedToInternet) }
        continuation.yield(.connection(.connected))
        if owner.holdStarts.contains(id) { await withCheckedContinuation { startGate = $0 } }
        return CoreSessionSnapshot(liveDate: owner.origin, duration: 42, userID: "viewer",
                                   messages: [chat("history", at: 5, counts: ["👍": 2])], polls: [poll()])
    }
    func stop() async {
        guard !stopped else { return }
        if owner.holdStop { await withCheckedContinuation { owner.stopGate = $0 } }
        stopped = true; owner.live.remove(ObjectIdentifier(self)); continuation.finish()
    }
    func sendChat(_ text: String) async throws -> CoreChat {
        sends += 1
        return CoreChat(id: "server-\(sends)", author: "Confirmed viewer", text: text,
                        createdAt: owner.origin.addingTimeInterval(1000))
    }
    func addReaction(_ type: String, to messageID: String) async throws -> CoreMessageReaction {
        .init(messageID: messageID, userID: "viewer", type: type)
    }
    func vote(pollID: String, optionID: String) async throws {
        votes.append(optionID); continuation.yield(.poll(poll(vote: optionID)))
    }
    func chat(_ id: String, at offset: Double, counts: [String: Int] = [:]) -> CoreChat {
        .init(id: id, author: "History", text: id, createdAt: owner.origin.addingTimeInterval(offset), counts: counts)
    }
    func poll(vote: String? = nil) -> CorePoll {
        .init(id: "poll", question: "Replay?", createdAt: owner.origin.addingTimeInterval(2), viewerVote: vote,
              options: [.init(id: "yes", text: "Yes", votes: vote == nil ? 2 : 3)])
    }
}

@MainActor final class CoreInteractionTests: XCTestCase {
    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for session/state", file: file, line: line)
    }
    private func leave(_ source: CoreInteractionSource, _ factory: Sessions, _ items: [HMMediaItem]) async {
        items.forEach { source.didLeave($0) }
        await waitUntil { factory.live.isEmpty }
    }

    func testTwoSessionsPromotionBackwardSwapAndStopBarrier() async {
        let factory = Sessions()
        let source = CoreInteractionSource(factory: factory)
        // Timeline construction is inert, even for HotMic references.
        _ = source.timeline(for: .hotmicStream("unused"))
        let interactions = CoreInteractionSource(factory: factory)
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
        let source = CoreInteractionSource(factory: factory)
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
        let removal = CoreMessageReaction(messageID: "history", userID: "viewer", type: "like")
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
        session.continuation.yield(.chat(messages: [session.chat("batch", at: 6), session.chat("server-1", at: 7)], reactions: []))
        session.continuation.yield(.poll(session.poll()))
        session.continuation.yield(.connection(.reconnecting(attempt: 2)))
        await waitUntil { source.connectionState(for: item) == .reconnecting(attempt: 2) }
        XCTAssertTrue(engagement.polls.isEmpty)
        XCTAssertFalse(engagement.messages(near: 7).contains { ["batch", "server-1"].contains($0.id) })
        session.continuation.yield(.connection(.connected))
        await waitUntil { source.connectionState(for: item) == .connected }
        XCTAssertEqual(factory.sessions["one"]?.count, 1, "Core reconnects in the existing session")
        await leave(source, factory, [item])
    }

    func testStartupBufferAndCancelledStartCannotOverwriteNewWindow() async {
        let factory = Sessions()
        let interactions = CoreInteractionSource(factory: factory)
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
        await waitUntil { timeline.duration == 42 && (timeline as? CoreTimeline)?.messages["history"] == nil && engagement.polls.isEmpty }
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

    func testMediaOffsetsClampAndUnsupportedItemsStayEmpty() async throws {
        let factory = Sessions(), source = CoreInteractionSource(factory: Sessions())
        let timeline = CoreTimeline(streamID: "one", duration: 42, liveDate: factory.origin)
        XCTAssertEqual(timeline.offset(factory.origin.addingTimeInterval(-10)), 0)
        XCTAssertEqual(timeline.offset(factory.origin.addingTimeInterval(12)), 12)
        XCTAssertEqual(timeline.offset(factory.origin.addingTimeInterval(100)), 42)
        timeline.retime(liveDate: nil, duration: nil)
        XCTAssertEqual(timeline.offset(factory.origin), 0, "Unknown stream origin must not invent epoch offsets")
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
        let interactions = CoreInteractionSource(factory: factory), item = HMMediaItem.hotmicStream("next")
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
}
