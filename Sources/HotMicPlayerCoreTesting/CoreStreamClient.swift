import Foundation
import HotMicCore
import HotMicPlayerCore

/// Injectable stream transport. Implement with a Sendable value or actor; production uses HotMicClient.
public protocol CoreStreamClient: Sendable {
    /// Fetches one stream summary by its Core ID.
    func fetchStream(id: String) async throws -> CoreStreamSummary
    /// Fetches a numbered catalogue page preserving the supplied query.
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
