import Foundation
import HotMicCore
import HotMicPlayer

/// Injectable stream transport. Implement with a Sendable value or actor; production uses HotMicClient.
public protocol CoreStreamClient: Sendable {
    /// Fetches one stream summary by its Core ID.
    func fetchStream(id: String) async throws -> CoreStreamSummary
    /// Fetches one stream summary by its Core ID.
    func fetchStreams(matching query: HotMicStreamQuery) async throws -> CoreStreamPage
}

/// A transport-independent stream summary. Sendable; mutate only exclusively owned values.
public struct CoreStreamSummary: Sendable {
    /// The Core stream ID.
    public let id: String
    /// Whether the stream is a recorded VOD.
    public let isVOD: Bool
    /// Playable VOD URL; nil means unavailable.
    public let vodURL: URL?
    /// Optional poster image URL.
    public var thumbnail: URL? = nil
    /// Optional stream title.
    public var title: String? = nil
    /// Optional recording duration in seconds.
    public var duration: TimeInterval? = nil

    /// Creates a stream summary for an injected client.
    public init(id: String, isVOD: Bool, vodURL: URL?, thumbnail: URL? = nil,
         title: String? = nil, duration: TimeInterval? = nil) {
        self.id = id; self.isVOD = isVOD; self.vodURL = vodURL
        self.thumbnail = thumbnail; self.title = title; self.duration = duration
    }

    init(_ summary: HotMicStreamSummary) {
        self.init(id: summary.id, isVOD: summary.state == .vod, vodURL: summary.vodURL,
                  thumbnail: summary.thumbnail, title: summary.title, duration: summary.duration)
    }

    func resolvedItem() throws -> HMResolvedItem {
        guard isVOD else { throw HotMicPlayerCoreError.notVOD(streamID: id) }
        guard let vodURL else { throw HotMicPlayerCoreError.missingVODURL(streamID: id) }
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
public struct CoreStreamPage: Sendable {
    /// Stream summaries in server order.
    public let streams: [CoreStreamSummary]
    /// The page number actually returned by the backend.
    public let currentPage: Int
    /// Whether the catalogue contains another page.
    public let hasNext: Bool

    /// Creates a catalogue page for an injected client.
    public init(streams: [CoreStreamSummary], currentPage: Int, hasNext: Bool) {
        self.streams = streams; self.currentPage = currentPage; self.hasNext = hasNext
    }
}

struct LiveCoreStreamClient: CoreStreamClient {
    let client: HotMicClient

    /// Fetches one stream summary by its Core ID.
    func fetchStream(id: String) async throws -> CoreStreamSummary {
        CoreStreamSummary(try await client.fetchStream(id: id))
    }

    /// Fetches one stream summary by its Core ID.
    func fetchStreams(matching query: HotMicStreamQuery) async throws -> CoreStreamPage {
        let page = try await client.fetchStreams(matching: query)
        return CoreStreamPage(streams: page.streams.map(CoreStreamSummary.init),
                              currentPage: page.pagination.currentPage, hasNext: page.pagination.hasNext)
    }
}
