import Foundation
import HotMicCore
import HotMicPlayer

// Core's binary summary/page types have no public initializers. Keep this projection
// at the boundary so fakes need neither production networking nor binary internals.
@_spi(Testing) public protocol CoreStreamClient: Sendable {
    func fetchStream(id: String) async throws -> CoreStreamSummary
    func fetchStreams(matching query: HotMicStreamQuery) async throws -> CoreStreamPage
}

@_spi(Testing) public struct CoreStreamSummary: Sendable {
    public let id: String
    public let isVOD: Bool
    public let vodURL: URL?
    public var thumbnail: URL? = nil
    public var title: String? = nil
    public var duration: TimeInterval? = nil

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
                           posterURL: resolved.poster, title: resolved.title, durationHint: resolved.duration)
    }
}

@_spi(Testing) public struct CoreStreamPage: Sendable {
    public let streams: [CoreStreamSummary]
    public let currentPage: Int
    public let hasNext: Bool

    public init(streams: [CoreStreamSummary], currentPage: Int, hasNext: Bool) {
        self.streams = streams; self.currentPage = currentPage; self.hasNext = hasNext
    }
}

struct LiveCoreStreamClient: CoreStreamClient {
    let client: HotMicClient

    func fetchStream(id: String) async throws -> CoreStreamSummary {
        CoreStreamSummary(try await client.fetchStream(id: id))
    }

    func fetchStreams(matching query: HotMicStreamQuery) async throws -> CoreStreamPage {
        let page = try await client.fetchStreams(matching: query)
        return CoreStreamPage(streams: page.streams.map(CoreStreamSummary.init),
                              currentPage: page.pagination.currentPage, hasNext: page.pagination.hasNext)
    }
}
