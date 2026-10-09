import SwiftUI
import Observation
import HotMicCore
import HotMicPlayer
import HotMicPlayerCore

/// Shared credential/fake setup, leaving the two app entry points small.
@MainActor @Observable final class ExampleIntegration {
    let player: HMPlayer
    let interactions: CoreInteractionSource?
    let isFake: Bool
    var streamID = "sample-6"
    private let playlist: CorePlaylistSource
    @ObservationIgnored private var eventsTask: Task<Void, Never>?

    init(engagement: Bool) {
        let resolver: CoreItemResolver
        if !ProcessInfo.processInfo.arguments.contains("--fake"), let credentials = DemoCredentials.load() {
            let client = HotMicClient(apiKey: credentials.HOTMIC_API_KEY, accessToken: credentials.HOTMIC_ACCESS_TOKEN)
            resolver = CoreItemResolver(client: client)
            playlist = CorePlaylistSource(client: client)
            interactions = engagement ? CoreInteractionSource(client: client) : nil
            isFake = false
        } else {
            let client = DemoClient()
            resolver = CoreItemResolver(client: client)
            playlist = CorePlaylistSource(client: client)
            interactions = engagement ? CoreInteractionSource(factory: DemoSessions()) : nil
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
                // Snapshot and item both lack duration. Send before timing arrives.
                try await engagement.sendChat("Send before duration", at: 2)
                await DemoEvidence.shared.record("unknownDurationSend", ["offset": String(interactions.timeline(for: item).events(in: 2...2).first?.offset ?? -1)])
                try await Task.sleep(for: .seconds(3))
                try await engagement.react("👍", toMessage: "sample-1-welcome")
                try await engagement.vote(pollID: "sample-1-poll", optionID: "yes")
                let messages = engagement.messages(near: 5, lookback: 5, limit: 100)
                await DemoEvidence.shared.record("recoveredTiming", ["history": String(messages.contains { $0.id == "sample-1-welcome" }), "ownAt2": String(messages.contains { $0.isOwn && $0.offset == 2 }), "messages": String(messages.count), "polls": String(engagement.polls.count), "vote": engagement.polls.first?.viewerVote ?? "pending"])
                try await Task.sleep(for: .seconds(10))
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
