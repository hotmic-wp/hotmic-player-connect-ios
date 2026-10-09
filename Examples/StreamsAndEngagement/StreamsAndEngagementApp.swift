import SwiftUI
import HotMicPlayer
import HotMicPlayerUI
import HotMicPlayerCore

@main struct StreamsAndEngagementApp: App {
    var body: some Scene { WindowGroup { EngagementFeed() } }
}

@MainActor struct EngagementFeed: View {
    @State private var integration = ExampleIntegration(engagement: true)
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        VStack {
            Text("HotMic Streams + Engagement").font(.headline)
            Text(integration.isFake ? "Fake client · public videos" : "Authenticated Core")
                .font(.caption)
            HMVerticalFeedView(player: integration.player, layout: HMOverlayLayout.self)
                .hmTheme(HMTheme(colors: HMTheme.default.colors, fonts: HMTheme.default.fonts,
                                 icons: HMTheme.default.icons, cornerRadius: HMTheme.default.cornerRadius,
                                 reactionPalette: ["👍", "🔥", "😆", "😡", "😢"], messageReaction: "👍"))
            if let item = integration.player.currentItem, let source = integration.interactions {
                Text("Engagement: \(String(describing: source.connectionState(for: item)))").font(.caption)
            }
            Text("\(integration.player.items.count) items · \(integration.player.hasMoreContent ? "More pages" : "End")")
            HStack {
                Button("Previous") { integration.player.previous() }
                Button("Play / Pause") { integration.player.togglePlayPause() }
                Button("Next") { integration.player.next() }
            }.buttonStyle(.bordered)
            HStack {
                TextField("VOD stream ID", text: $integration.streamID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Play ID") { integration.playID() }
                Button("Feed") { Task { await integration.start() } }
            }.padding(.horizontal)
        }
        .task { await integration.start(); await integration.verify() }
        .onChange(of: scenePhase) { _, phase in integration.player.isFeedVisible = phase == .active }
        .onAppear { integration.player.isFeedVisible = true }
        .onDisappear { integration.player.teardown() }
    }
}
