import Foundation
import HotMicCore
import HotMicPlayer

/// Pages Core summaries into direct VOD URL items without per-stream fetches.
/// Non-VOD and missing-URL entries are filtered before reaching the player.
public struct CorePlaylistSource: HMPlaylistSource {
    private let client: any CoreStreamClient
    private let query: HotMicStreamQuery

    /// The default query includes VOD only. A supplied query retains its filters,
    /// user and limit; its page is the starting page when the cursor is nil.
    public init(client: HotMicClient, query: HotMicStreamQuery = HotMicStreamQuery(
        includesLive: false, includesScheduled: false, includesVOD: true
    )) {
        self.init(client: LiveCoreStreamClient(client: client), query: query)
    }

    /// Creates an adapter with an injectable client, for offline previews or custom transport.
    public init(client: any CoreStreamClient, query: HotMicStreamQuery = HotMicStreamQuery(
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
                throw HotMicPlayerCoreError.invalidCursor(cursor)
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
                throw HotMicPlayerCoreError.invalidPagination
            }
            nextCursor = String(page.currentPage + 1)
        } else {
            nextCursor = nil
        }
        return HMPlaylistPage(items: page.streams.compactMap { try? $0.playlistItem() }, nextCursor: nextCursor)
    }
}
