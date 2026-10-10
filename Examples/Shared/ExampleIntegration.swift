import SwiftUI
import Observation
import HotMicCore
import HotMicPlayer
import HotMicPlayerConnect
import HotMicPlayerConnectTesting

/// Shared credential/fake setup, leaving the two app entry points small.
@MainActor @Observable final class ExampleIntegration {
    let player: HMPlayer
    let interactions: HotMicInteractionSource?
    let isFake: Bool
    var streamID = "sample-6"
    private let playlist: HotMicPlaylistSource
    @ObservationIgnored private var eventsTask: Task<Void, Never>?

    init(engagement: Bool) {
        let resolver: HotMicItemResolver
        if !ProcessInfo.processInfo.arguments.contains("--fake"), let credentials = DemoCredentials.load() {
            let client = HotMicClient(apiKey: credentials.HOTMIC_API_KEY, accessToken: credentials.HOTMIC_ACCESS_TOKEN)
            resolver = HotMicItemResolver(client: client)
            playlist = HotMicPlaylistSource(client: client)
            interactions = engagement ? HotMicInteractionSource(client: client) : nil
            isFake = false
        } else {
            let client = DemoClient()
            resolver = HotMicItemResolver(client: client)
            playlist = HotMicPlaylistSource(client: client)
            interactions = engagement ? HotMicInteractionSource(factory: DemoSessions()) : nil
            isFake = true
        }
        if let interactions { player = HMPlayer(resolver: resolver, interactions: interactions) }
        else { player = HMPlayer(resolver: resolver) }
        // Subscribe before start. Only fixture IDs and safe event names go to evidence.
        if isFake {
            let events = player.events
            eventsTask = Task {
                for await event in events {
                    guard !Task.isCancelled else { break }
                    switch event {
                    case .firstFrame(let item, _, _): await DemoEvidence.shared.record("firstFrame", ["id": item.id])
                    case .playlistChanged(let items): await DemoEvidence.shared.record("playlist", ["ids": items.map(\.id).joined(separator: ",")])
                    case .error(let item, _): await DemoEvidence.shared.record("itemError", ["id": item?.id ?? "none"])
                    default: break
                    }
                }
            }
        }
    }
    deinit { eventsTask?.cancel() }
    func start() async {
        player.playlistSource = playlist
        player.replaceAll([])
        await player.start()
    }
    func playID() {
        player.playlistSource = nil
        player.replaceAll([.hotmicStream(streamID)])
        player.play()
    }

    /// Fake-only end-to-end evidence. No credential or real API path can enter this script.
    func verify() async {
        guard isFake, ProcessInfo.processInfo.arguments.contains("--verify") else { return }
        do {
            try await Task.sleep(for: .milliseconds(300))
            player.pause()
            guard let item = player.currentItem else { throw CancellationError() }
            if let interactions {
                let engagement = player.engagement(for: item)
                for _ in 0..<30 where engagement.reactionSummary(for: "🔥") == nil {
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard let before = engagement.reactionSummary(for: "🔥"), before.reactedByViewer == false else { throw CancellationError() }
                try await engagement.toggleReaction("🔥")
                guard let fired = engagement.reactionSummary(for: "🔥"), fired.reactedByViewer, fired.count == before.count + 1 else { throw CancellationError() }
                await DemoEvidence.shared.record("itemReaction", ["count": String(fired.count), "reacted": "true"])
                let replay = engagement.messages(near: 42, lookback: 42, limit: 200).map(\.id)
                try await engagement.loadComments()
                try await engagement.loadComments()
                let rows = engagement.comments().map(\.id)
                guard rows.contains(where: { $0.hasSuffix("comment-new-1") }),
                      rows.contains(where: { $0.hasSuffix("comment-old-1") }),
                      engagement.olderCommentsCursor == nil,
                      engagement.messages(near: 42, lookback: 42, limit: 200).map(\.id) == replay,
                      replay.allSatisfy({ !$0.contains("comment-") }) else { throw CancellationError() }
                await DemoEvidence.shared.record("itemComments", ["rows": rows.joined(separator: ","), "count": String(engagement.commentCount ?? -1)])
                // Snapshot and item both lack duration. Send before timing arrives.
                try await engagement.sendChat("Send before duration", at: 2)
                await DemoEvidence.shared.record("unknownDurationSend", ["offset": String(interactions.timeline(for: item).events(in: 2...2).first?.offset ?? -1)])
                try await Task.sleep(for: .seconds(3))
                try await engagement.react("👍", toMessage: "sample-1-welcome")
                try await engagement.vote(pollID: "sample-1-poll", optionID: "yes")
                let messages = engagement.messages(near: 5, lookback: 5, limit: 100)
                await DemoEvidence.shared.record("recoveredTiming", ["history": String(messages.contains { $0.id == "sample-1-welcome" }), "ownAt2": String(messages.contains { $0.isOwn && $0.offset == 2 }), "messages": String(messages.count), "polls": String(engagement.polls.count), "vote": engagement.polls.first?.viewerVote ?? "pending"])
                try await Task.sleep(for: .seconds(10))
                let comments = engagement.comments().map(\.id)
                guard comments.contains(where: { $0.hasSuffix("comment-live") }),
                      !engagement.messages(near: 42, lookback: 42, limit: 200).contains(where: { $0.id.contains("comment-") }) else { throw CancellationError() }
                await DemoEvidence.shared.record("liveComment", ["present": "true", "count": String(engagement.commentCount ?? -1)])
                await DemoEvidence.shared.record("moderation", ["deletedChatHidden": String(!engagement.messages(near: 5, lookback: 5, limit: 100).contains { $0.id == "sample-1-batch" }), "deletedPollHidden": String(engagement.polls.isEmpty)])
            }
            // Advance until page two is fetched (overlap de-duplicated by player).
            for _ in 0..<5 { player.next(); player.pause(); try await Task.sleep(for: .milliseconds(200)) }
            try await Task.sleep(for: .seconds(2))
            await DemoEvidence.shared.record("paged", ["items": String(player.items.count), "hasMore": String(player.hasMoreContent)])
            streamID = "sample-6"; playID()
            try await Task.sleep(for: .seconds(2))
            player.isFeedVisible = false
            await DemoEvidence.shared.record("verifyComplete", ["level": interactions == nil ? "streams" : "engagement"])
        } catch { await DemoEvidence.shared.record("verifyFailed") }
    }
}
