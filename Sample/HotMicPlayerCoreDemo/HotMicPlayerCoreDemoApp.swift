import SwiftUI
import Observation
import HotMicCore
import HotMicPlayer
import HotMicPlayerUI
@_spi(Testing) import HotMicPlayerCore

@main
struct HotMicPlayerCoreDemoApp: App {
    var body: some Scene { WindowGroup { DemoView() } }
}

@MainActor @Observable
final class DemoModel {
    let player: HMPlayer
    let isFake: Bool
    private let resolver: CoreItemResolver
    private let source: CorePlaylistSource
    let interactions: CoreInteractionSource
    private let fakeSessions: DemoSessions?
    private var eventsTask: Task<Void, Never>?
    var streamID = "sample-6"
    var message = ""
    var mode = "Feed"

    init() {
        if !ProcessInfo.processInfo.arguments.contains("--fake"), let credentials = DemoCredentials.load() {
            let client = HotMicClient(apiKey: credentials.HOTMIC_API_KEY,
                                      accessToken: credentials.HOTMIC_ACCESS_TOKEN)
            resolver = CoreItemResolver(client: client)
            source = CorePlaylistSource(client: client)
            interactions = CoreInteractionSource(client: client)
            fakeSessions = nil
            isFake = false
        } else {
            let client = DemoClient()
            resolver = CoreItemResolver(client: client)
            source = CorePlaylistSource(client: client)
            let sessions = DemoSessions()
            fakeSessions = sessions
            interactions = CoreInteractionSource(factory: sessions)
            isFake = true
        }
        player = HMPlayer(resolver: resolver, interactions: interactions)
        let events = player.events
        eventsTask = Task { @MainActor [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                switch event {
                case .error(let item, _):
                    let terminal = await HMPlayer.terminalHotMicItem(in: event, using: self.resolver) != nil
                    if terminal {
                        self.message = "Item error: \(item?.id ?? "") skipped (not playable VOD)."
                    } else {
                        self.message = "Playback or network error. Check connectivity and credentials."
                    }
                    self.record("itemError", ["id": item?.id ?? "", "terminal": String(terminal)])
                case .playlistChanged(let items):
                    self.record("playlist", ["ids": items.map(\.id).joined(separator: ",")])
                case .currentItemChanged(let item):
                    self.record("current", ["id": item?.id ?? "none"])
                case .firstFrame(let item, _, _):
                    self.record("firstFrame", ["id": item.id])
                case .sourcePageDuplicates(let ids):
                    self.record("duplicates", ["ids": ids.joined(separator: ",")])
                default: break
                }
            }
        }
    }

    func feed() async {
        mode = "Feed"; message = ""
        player.playlistSource = source
        player.replaceAll([])
        await player.start()
    }

    func byID(_ id: String) {
        mode = "By ID"; message = ""
        player.playlistSource = nil
        // In fake mode the second entry proves recovery after a terminal error.
        let ids = isFake && id != "sample-1" ? [id, "sample-1"] : [id]
        player.replaceAll(ids.map(HMMediaItem.hotmicStream))
        player.play()
    }

    /// Opt-in fake-only app flow, using the same player/engagement actions as the overlay.
    func runReviewScript() async {
        guard isFake, ProcessInfo.processInfo.arguments.contains("--review-script") else { return }
        do {
            record("reviewBegin", [:])
            // Keep the short MP4 current through the retry, 50-message batch and moderation.
            player.pause()
            try await Task.sleep(for: .seconds(4))
            guard let item = player.currentItem else { return }
            let engagement = player.engagement(for: item)
            reviewProjection("batchAndBoundaries", item: item)
            try await engagement.sendChat("Review confirmed send", at: 2)
            try await engagement.react("👍", toMessage: "sample-1-welcome")
            try await engagement.vote(pollID: "sample-1-poll", optionID: "yes")
            player.seek(to: 2)
            reviewProjection("actions", item: item)
            try await Task.sleep(for: .seconds(4))
            record("reviewConnection", ["state": String(describing: interactions.connectionState(for: item))])
            try await Task.sleep(for: .seconds(6))
            reviewProjection("afterDeletions", item: item)

            // Two obsolete sessions: next's fast stop must release capacity before current's slow stop.
            fakeSessions?.slowStops.insert("sample-1")
            player.playlistSource = nil
            record("fastBingeBegin", [:])
            player.replaceAll(["sample-3", "sample-4", "sample-5", "sample-6", "sample-7"].map(HMMediaItem.hotmicStream))
            for _ in 0..<3 {
                try await Task.sleep(for: .milliseconds(150))
                player.next()
            }
            player.pause()
            try await Task.sleep(for: .seconds(4))
            record("fastBingeEnd", ["maximumLive": String(fakeSessions?.maximumLive ?? 0)])
            // Sample-7 intentionally has no liveDate: history/polls must stay empty, own sends work.
            player.next(); player.pause()
            try await Task.sleep(for: .seconds(3))
            guard let missing = player.currentItem else { return }
            reviewProjection("missingOrigin", item: missing)
            try await player.engagement(for: missing).sendChat("Own send without origin", at: 2)
            player.seek(to: 2)
            reviewProjection("missingOriginOwnSend", item: missing)
            record("reviewComplete", ["maximumLive": String(fakeSessions?.maximumLive ?? 0)])
        } catch {
            // Deliberately no raw errors or credentials in fake evidence.
            record("reviewFailed", [:])
        }
    }

    private func reviewProjection(_ stage: String, item: HMMediaItem) {
        let engagement = player.engagement(for: item)
        let messages = engagement.messages(near: engagement.duration, lookback: engagement.duration, limit: 100)
        record("reviewProjection", ["stage": stage, "id": item.id,
                                    "messages": String(messages.count),
                                    "outsideMessages": String(messages.filter { $0.id.contains("pre-live") || $0.id.contains("post-vod") }.count),
                                    "polls": engagement.polls.map(\.id).joined(separator: ","),
                                    "endBucket": String(engagement.density.last?.eventCount ?? 0),
                                    "waveformEvents": String(engagement.density.reduce(0) { $0 + $1.eventCount }),
                                    "own": messages.filter(\.isOwn).map { "\($0.id)@\($0.offset)" }.joined(separator: ","),
                                    "welcomeLikes": String(messages.first { $0.id.hasSuffix("-welcome") }?.reactions["👍"] ?? 0),
                                    "vote": engagement.polls.first?.viewerVote ?? "none"])
    }

    func visibility(_ visible: Bool) { player.isFeedVisible = visible }

    func stop() {
        eventsTask?.cancel(); player.teardown()
    }

    private func record(_ event: String, _ fields: [String: String]) {
        guard isFake else { return }
        Task { await DemoEvidence.shared.record(event, fields) }
    }
}

struct DemoView: View {
    @State private var model = DemoModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 8) {
            Text("HotMic Core VOD").font(.headline)
            Text(model.isFake ? "No credentials — fake client with public videos." : "Authenticated Core client")
                .font(.caption).accessibilityIdentifier("credentialStatus")
            HStack {
                Button("Feed") { Task { await model.feed() } }
                TextField("Stream ID", text: $model.streamID)
                    .textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .accessibilityIdentifier("streamID")
                Button("Play ID") { model.byID(model.streamID) }
            }.padding(.horizontal)
            if model.isFake {
                HStack {
                    Button("Non-VOD") { model.byID("bad-live") }
                    Button("Missing URL") { model.byID("bad-missing") }
                }.buttonStyle(.bordered)
            }
            Text(model.message).font(.caption).foregroundStyle(.orange)
                .accessibilityIdentifier("itemMessage")
            if let item = model.player.currentItem {
                Text("Engagement: \(String(describing: model.interactions.connectionState(for: item)))")
                    .font(.caption).accessibilityIdentifier("engagementStatus")
            }
            HMVerticalFeedView(player: model.player, layout: HMOverlayLayout.self)
                .hmTheme(HMTheme(colors: HMTheme.default.colors, fonts: HMTheme.default.fonts,
                                 icons: HMTheme.default.icons, cornerRadius: HMTheme.default.cornerRadius,
                                 reactionPalette: ["👍", "🔥", "😆", "😡", "😢"], messageReaction: "👍"))
                .frame(maxHeight: .infinity)
            Text("\(model.mode) • \(model.player.items.count) items • \(model.player.hasMoreContent ? "More pages" : "End of feed")")
                .font(.caption).accessibilityIdentifier("feedStatus")
            HStack {
                Button("Previous") { model.player.previous() }
                Button("Play / Pause") { model.player.togglePlayPause() }
                Button("Next") { model.player.next() }
            }.buttonStyle(.bordered)
        }
        .task { await model.feed(); await model.runReviewScript() }
        .onChange(of: scenePhase) { _, phase in model.visibility(phase == .active) }
        .onDisappear { model.stop() }
    }
}
