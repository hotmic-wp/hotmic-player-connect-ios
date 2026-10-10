import SwiftUI
import HotMicPlayer
import HotMicPlayerUI
import HotMicPlayerConnect

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
                ItemEngagementControls(player: integration.player, item: item)
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

/// Fire membership, the comment count, and older item comments. Replay stays on the overlay timeline.
@MainActor private struct ItemEngagementControls: View {
    let player: HMPlayer
    let item: HMMediaItem
    var body: some View {
        let engagement = player.engagement(for: item)
        let summary = engagement.reactionSummary(for: "🔥")
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    Task { try? await engagement.toggleReaction("🔥") }
                } label: {
                    Label(summary.map { HMCountFormatter().string(from: $0.count) } ?? "—",
                          systemImage: summary?.reactedByViewer == true ? "flame.fill" : "flame")
                }
                .disabled(summary == nil)
                .accessibilityIdentifier("connect-fire")
                .accessibilityValue(summary.map { "\($0.count) \($0.reactedByViewer ? "reacted" : "not reacted")" } ?? "unknown")
                Text(engagement.commentCount.map { "\($0) comments" } ?? "Comments —")
                    .font(.caption)
                    .accessibilityIdentifier("connect-comment-count")
                Button(engagement.hasLoadedComments ? "Older comments" : "Load comments") {
                    Task { try? await engagement.loadComments() }
                }
                .disabled(!engagement.supports(.loadComments) || engagement.isLoadingComments
                          || (engagement.hasLoadedComments && engagement.olderCommentsCursor == nil))
                .accessibilityIdentifier("connect-older-comments")
            }
            .buttonStyle(.bordered)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(engagement.comments(), id: \.rowID) { message in
                    Text("\(message.author): \(message.text)").font(.caption).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("connect-comment-list")
        }
        .padding(.horizontal)
        .task(id: item.id) {
            guard !ProcessInfo.processInfo.arguments.contains("--verify") else { return }
            let engagement = player.engagement(for: item)
            for _ in 0..<30 {
                guard engagement.supports(.loadComments), !engagement.hasLoadedComments else { return }
                do { try await engagement.loadComments(); return }
                catch { try? await Task.sleep(for: .milliseconds(100)) }
            }
        }
    }
}
