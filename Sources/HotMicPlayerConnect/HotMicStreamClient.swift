import Foundation
import HotMicCore
import HotMicPlayer

/// Injectable stream transport. Implement with a Sendable value or actor; production uses HotMicClient.
package protocol _HotMicStreamClient: Sendable {
    /// Fetches one stream summary by its Core ID.
    func fetchStream(id: String) async throws -> _HotMicStreamSummary
    /// Fetches one stream summary by its Core ID.
    func fetchStreams(matching query: HotMicStreamQuery) async throws -> _HotMicStreamPage
}

/// A transport-independent stream summary. Sendable; mutate only exclusively owned values.
package struct _HotMicStreamSummary: Sendable {
    /// The Core stream ID.
    package let id: String
    /// Whether the stream is a recorded VOD.
    package let isVOD: Bool
    /// Playable VOD URL; nil means unavailable.
    package let vodURL: URL?
    /// Optional poster image URL.
    package var thumbnail: URL? = nil
    /// Optional stream title.
    package var title: String? = nil
    /// Optional recording duration in seconds.
    package var duration: TimeInterval? = nil

    /// Creates a stream summary for an injected client.
    package init(id: String, isVOD: Bool, vodURL: URL?, thumbnail: URL? = nil,
         title: String? = nil, duration: TimeInterval? = nil) {
        self.id = id; self.isVOD = isVOD; self.vodURL = vodURL
        self.thumbnail = thumbnail; self.title = title; self.duration = duration
    }

    init(_ summary: HotMicStreamSummary) {
        self.init(id: summary.id, isVOD: summary.state == .vod, vodURL: summary.vodURL,
                  thumbnail: summary.thumbnail, title: summary.title, duration: summary.duration)
    }

    func resolvedItem() throws -> HMResolvedItem {
        guard isVOD else { throw HotMicPlayerConnectError.notVOD(streamID: id) }
        guard let vodURL else { throw HotMicPlayerConnectError.missingVODURL(streamID: id) }
        return HMResolvedItem(url: vodURL, format: .auto, poster: thumbnail, title: title, duration: duration)
    }

    func playlistItem() throws -> HMMediaItem {
        let resolved = try resolvedItem()
        return HMMediaItem(id: HMMediaItem.hotmicStream(id).id, source: .url(resolved.url, format: .auto),
                           posterURL: resolved.poster, title: resolved.title, durationHint: resolved.duration,
                           metadata: ["hotmic.namespace": "hotmic", "hotmic.streamID": id])
    }
}

/// One numbered catalogue page. Sendable across tasks.
package struct _HotMicStreamPage: Sendable {
    /// Stream summaries in server order.
    package let streams: [_HotMicStreamSummary]
    /// The page number actually returned by the backend.
    package let currentPage: Int
    /// Whether the catalogue contains another page.
    package let hasNext: Bool

    /// Creates a catalogue page for an injected client.
    package init(streams: [_HotMicStreamSummary], currentPage: Int, hasNext: Bool) {
        self.streams = streams; self.currentPage = currentPage; self.hasNext = hasNext
    }
}

struct LiveHotMicStreamClient: _HotMicStreamClient {
    let client: HotMicClient

    /// Fetches one stream summary by its Core ID.
    func fetchStream(id: String) async throws -> _HotMicStreamSummary {
        _HotMicStreamSummary(try await client.fetchStream(id: id))
    }

    /// Fetches one stream summary by its Core ID.
    func fetchStreams(matching query: HotMicStreamQuery) async throws -> _HotMicStreamPage {
        let page = try await client.fetchStreams(matching: query)
        return _HotMicStreamPage(streams: page.streams.map(_HotMicStreamSummary.init),
                              currentPage: page.pagination.currentPage, hasNext: page.pagination.hasNext)
    }
}
