// Compiles the README integration with an ordinary partner import.
import SwiftUI
import HotMicCore
import HotMicPlayer
import HotMicPlayerUI
import HotMicPlayerCore
@MainActor struct Feed: View {
    @State private var player: HMPlayer
    init(client: HotMicClient) {
        let player = HMPlayer(resolver: CoreItemResolver(client: client),
                              interactions: CoreInteractionSource(client: client))
        player.playlistSource = CorePlaylistSource(client: client)
        _player = State(initialValue: player)
    }
    var body: some View { HMVerticalFeedView(player: player, layout: HMOverlayLayout.self).task { await player.start() } }
}
