import SwiftUI
import HotMicPlayer
import HotMicPlayerConnect

@main struct StreamsApp: App {
    var body: some Scene { WindowGroup { StreamsFeed() } }
}

@MainActor struct StreamsFeed: View {
    @State private var integration = ExampleIntegration(engagement: false)
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        VStack {
            Text("HotMic Streams").font(.headline)
            Text(integration.isFake ? "Fake client · public videos" : "Authenticated Core")
                .font(.caption)
            HMVerticalFeedView(player: integration.player)
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
