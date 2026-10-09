import Foundation
import HotMicCore
import HotMicPlayer

/// Pages Core summaries into direct VOD URL items without per-stream fetches.
/// Non-VOD and missing-URL entries are filtered before reaching the player.
public struct HotMicPlaylistSource: HMPlaylistSource {
    private let client: any _HotMicStreamClient
    private let query: HotMicStreamQuery

    /// The default query includes VOD only. A supplied query retains its filters,
    /// user and limit; its page is the starting page when the cursor is nil.
    public init(client: HotMicClient, query: HotMicStreamQuery = HotMicStreamQuery(
        includesLive: false, includesScheduled: false, includesVOD: true
    )) {
        self.init(client: LiveHotMicStreamClient(client: client), query: query)
    }

    /// Creates an adapter with an injectable client, for offline previews or custom transport.
    package init(client: any _HotMicStreamClient, query: HotMicStreamQuery = HotMicStreamQuery(
        includesLive: false, includesScheduled: false, includesVOD: true
    )) {
        self.client = client
        self.query = query
    }

    /// Cursors are opaque to hosts. Nil starts/restarts the query; nil in the
    /// returned page ends it. Empty filtered pages can still have a next cursor.
    public func loadPage(cursor: String?) async throws -> HMPlaylistPage {
        try Task.checkCancellation()
        var request = query
        if let cursor {
            guard let page = Int(cursor), page > 0 else {
                throw HotMicPlayerConnectError.invalidCursor(cursor)
            }
            request.page = page
        } else {
            request.page = max(1, query.page)
        }
        let page = try await client.fetchStreams(matching: request)
        try Task.checkCancellation()
        let nextCursor: String?
        if page.hasNext {
            guard page.currentPage >= request.page, page.currentPage < Int.max else {
                throw HotMicPlayerConnectError.invalidPagination
            }
            nextCursor = String(page.currentPage + 1)
        } else {
            nextCursor = nil
        }
        return HMPlaylistPage(items: page.streams.compactMap { try? $0.playlistItem() }, nextCursor: nextCursor)
    }
}
