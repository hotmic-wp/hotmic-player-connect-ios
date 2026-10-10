import Foundation
import HotMicPlayer
import HotMicPlayerConnect
import HotMicPlayerConnectTesting

/// Runs only in fake mode. Timers model session batches, connection recovery and moderation.
@MainActor final class DemoSessions: HotMicSessionFactory {
    private(set) var live: Set<String> = []
    private(set) var maximumLive = 0
    var slowStops: Set<String> = []
    private var attempts: [String: Int] = [:]
    let reviewScript = ProcessInfo.processInfo.arguments.contains("--review-script")
    var itemEngagement: HMEngagementCapabilities { [.toggleReaction, .loadComments] }
    func shouldFail(_ id: String) -> Bool {
        attempts[id, default: 0] += 1
        return reviewScript && id == "sample-1" && attempts[id] == 1
    }
    func makeSession(streamID: String) -> any HotMicSession { DemoSession(id: streamID, owner: self) }
    func opened(_ id: String) {
        live.insert(id); maximumLive = max(maximumLive, live.count)
        record("sessionOpen", ["id": id, "live": live.sorted().joined(separator: ","), "count": String(live.count)])
    }
    func closed(_ id: String) {
        live.remove(id)
        record("sessionStop", ["id": id, "live": live.sorted().joined(separator: ","), "count": String(live.count)])
    }
    func record(_ event: String, _ fields: [String: String]) {
        Task { await DemoEvidence.shared.record(event, fields) }
    }
}

@MainActor private final class DemoSession: HotMicSession {
    let id: String
    weak var owner: DemoSessions?
    let events: AsyncStream<HotMicSessionEvent>
    let continuation: AsyncStream<HotMicSessionEvent>.Continuation
    private var script: Task<Void, Never>?
    private var active = false
    private var stopped = false
    private var number = 0
    private var fireCount = 12
    private var fireReacted = false
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    init(id: String, owner: DemoSessions) {
        self.id = id; self.owner = owner
        let pair = AsyncStream<HotMicSessionEvent>.makeStream()
        events = pair.stream; continuation = pair.continuation
    }
    deinit { script?.cancel(); continuation.finish() }
    func start() async throws -> HotMicSessionSnapshot {
        guard !stopped, !active else { throw CancellationError() }
        active = true; owner?.opened(id)
        if owner?.shouldFail(id) == true {
            owner?.record("transientStartFailure", ["id": id])
            throw URLError(.notConnectedToInternet)
        }
        continuation.yield(.connection(.connected))
        script = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
                guard let self, !self.stopped else { return }
                self.continuation.yield(.stream(liveDate: self.origin, duration: self.id == "sample-6" ? 1800 : 5.05))
                self.continuation.yield(.liveComment(self.chat("comment-live", "Live", "Just arrived", at: 400), totalCount: 7))
                self.owner?.record("timingArrived", ["id": self.id])
                self.owner?.record("liveComment", ["id": self.id])
                let batch = [self.chat("batch", "Sample participant", "This arrived in a chat batch", at: 0.5)] + (1..<50).map {
                    self.chat("burst-\($0)", "Replay viewer", "Batch message \($0)", at: 0.5 + Double($0) / 50)
                }
                self.continuation.yield(.chat(messages: batch, reactions: []))
                self.continuation.yield(.chat(messages: [self.chat("pre-live", "Before", "Before liveDate", at: -20),
                                                        self.chat("post-vod", "After", "After recording", at: 3600)], reactions: []))
                self.owner?.record("chatBatch", ["id": self.id, "batchSize": "50", "outsideWindow": "2"])
                try await Task.sleep(for: .seconds(1))
                self.continuation.yield(.poll(self.poll()))
                for (suffix, offset) in [("pre-live", -20.0), ("post-vod", 3600.0)] {
                    self.continuation.yield(.poll(HotMicFixturePoll(id: "\(self.id)-\(suffix)", question: "Outside recording",
                                                          createdAt: self.origin.addingTimeInterval(offset), options: [])))
                }
                self.owner?.record("pollCreated", ["id": self.id, "outsideWindow": "2"])
                try await Task.sleep(for: .seconds(4))
                self.continuation.yield(.connection(.reconnecting(attempt: 1)))
                self.owner?.record("reconnecting", ["id": self.id])
                try await Task.sleep(for: .seconds(3))
                self.continuation.yield(.connection(.connected))
                self.owner?.record("connected", ["id": self.id])
                try await Task.sleep(for: .seconds(3))
                self.continuation.yield(.messageDeleted("\(self.id)-batch"))
                self.continuation.yield(.pollDeleted("\(self.id)-poll"))
                self.owner?.record("scriptDeletions", ["id": self.id])
                try await Task.sleep(for: .milliseconds(200))
                self.continuation.yield(.chat(messages: [self.chat("batch", "Sample participant", "Deleted late echo", at: 0.5)], reactions: []))
                self.continuation.yield(.poll(self.poll()))
                self.owner?.record("lateModeratedEcho", ["id": self.id])
            } catch { }
        }
        return HotMicSessionSnapshot(liveDate: id == "sample-7" ? nil : origin, duration: id == "sample-1" ? nil : (id == "sample-6" ? 1800 : 5.05),
                                   userID: "demo-viewer", messages: [chat("welcome", "Sample host", "Welcome to \(id)", at: 0)], polls: [],
                                   itemReactions: [.init(emoji: "🔥", count: fireCount, reactedByViewer: fireReacted)], commentCount: 6)
    }
    func stop() async {
        guard !stopped else { return }
        stopped = true; script?.cancel(); continuation.finish()
        if active {
            owner?.record("sessionStopBegin", ["id": id])
            // Stopping remains live until the asynchronous cleanup finishes.
            try? await Task.sleep(for: .seconds(owner?.slowStops.contains(id) == true ? 3 : 0.1))
            active = false; owner?.closed(id)
        }
    }
    func sendChat(_ text: String) async throws -> HotMicChat {
        guard active, !stopped else { throw CancellationError() }
        number += 1
        let message = chat("sent-\(number)", "Demo viewer", text, at: 1000)
        owner?.record("chatSent", ["id": id, "messageID": message.id])
        // No event echo: adapter must return the server event and insert it itself.
        return message
    }
    func addReaction(_ type: String, to messageID: String) async throws -> HotMicMessageReaction {
        guard active, !stopped else { throw CancellationError() }
        owner?.record("reactionAdded", ["id": id, "messageID": messageID, "type": type])
        // Exercise reaction deletion, including clearing the viewer's selection.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !self.stopped else { return }
            self.continuation.yield(.reactionDeleted(.init(messageID: messageID, userID: "demo-viewer", type: type)))
            self.owner?.record("reactionDeleted", ["id": self.id, "messageID": messageID])
        }
        return HotMicMessageReaction(messageID: messageID, userID: "demo-viewer", type: type)
    }
    func setItemReaction(_ emoji: String, isReacted: Bool) async throws -> HotMicItemReaction {
        guard active, !stopped else { throw CancellationError() }
        guard emoji == "🔥" else { throw HMInteractionError.unsupportedAction }
        if fireReacted != isReacted {
            fireCount = max(0, fireCount + (isReacted ? 1 : -1))
            fireReacted = isReacted
        }
        owner?.record("itemReaction", ["id": id, "count": String(fireCount), "reacted": String(fireReacted)])
        return HotMicItemReaction(emoji: "🔥", count: fireCount, reactedByViewer: fireReacted)
    }
    func comments(before cursor: String?) async throws -> HotMicCommentPage {
        guard active, !stopped else { throw CancellationError() }
        if cursor == nil {
            owner?.record("commentPage", ["id": id, "cursor": "newest"])
            return HotMicCommentPage(comments: [
                comment("new-1", "Avery", "Newest comment", at: 300),
                comment("new-2", "Blake", "Still watching", at: 240),
                comment("new-3", "Casey", "Fire this", at: 180)
            ], olderCursor: "older")
        }
        guard cursor == "older" else { throw HMInteractionError.unsupportedAction }
        owner?.record("commentPage", ["id": id, "cursor": "older"])
        return HotMicCommentPage(comments: [
            comment("old-1", "Drew", "Earlier comment", at: 60),
            comment("old-2", "Ellis", "From the start", at: 30),
            comment("old-3", "Finn", "First in", at: 10)
        ])
    }
    func vote(pollID: String, optionID: String) async throws {
        guard active, !stopped else { throw CancellationError() }
        continuation.yield(.poll(poll(vote: optionID)))
        owner?.record("pollVoted", ["id": id, "optionID": optionID])
    }
    private func chat(_ suffix: String, _ author: String, _ text: String, at offset: TimeInterval) -> HotMicChat {
        HotMicChat(id: "\(id)-\(suffix)", author: author, text: text, createdAt: origin.addingTimeInterval(offset))
    }
    private func comment(_ suffix: String, _ author: String, _ text: String, at offset: TimeInterval) -> HotMicChat {
        chat("comment-\(suffix)", author, text, at: offset)
    }
    private func poll(vote: String? = nil) -> HotMicFixturePoll {
        HotMicFixturePoll(id: "\(id)-poll", question: "Watch another replay?", createdAt: origin,
                 viewerVote: vote, options: [.init(id: "yes", text: "Yes", votes: 2 + (vote == "yes" ? 1 : 0)),
                                            .init(id: "again", text: "Run it back", votes: 1 + (vote == "again" ? 1 : 0))])
    }
}
