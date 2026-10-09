import Foundation
import HotMicCore
import HotMicPlayer

/// Resolves `hotmic` references to VOD. Successful results use a bounded in-memory
/// LRU cache for 60 seconds. The player owns request coalescing and retries.
public actor CoreItemResolver: HMItemResolver {
    private let client: any _CoreStreamClient
    private let cacheCapacity: Int
    private var cache: [String: (item: HMResolvedItem, expires: TimeInterval)] = [:]
    private var recency: [String] = []
    /// Creates a resolver sharing the host's authenticated Core client.
    /// Set capacity to zero to disable the adapter cache.
    public init(client: HotMicClient, cacheCapacity: Int = 32) {
        self.init(client: LiveCoreStreamClient(client: client), cacheCapacity: cacheCapacity)
    }

    /// Creates an adapter with an injectable client, for offline previews or custom transport.
    package init(client: any _CoreStreamClient, cacheCapacity: Int = 32) {
        self.client = client
        self.cacheCapacity = max(0, cacheCapacity)
    }

    /// Resolves a HotMic VOD reference; cancellation and Core transport errors propagate.
    public func resolve(_ ref: HMMediaItem.Reference) async throws -> HMResolvedItem {
        try Task.checkCancellation()
        guard ref.namespace == "hotmic" else {
            throw HotMicPlayerCoreError.unsupportedNamespace(ref.namespace)
        }
        if let entry = cache[ref.id], entry.expires > ProcessInfo.processInfo.systemUptime {
            touch(ref.id)
            return entry.item
        }
        let summary = try await client.fetchStream(id: ref.id)
        try Task.checkCancellation()
        let item = try summary.resolvedItem()
        if cacheCapacity > 0 {
            cache[ref.id] = (item, ProcessInfo.processInfo.systemUptime + 60)
            touch(ref.id)
            while recency.count > cacheCapacity {
                cache.removeValue(forKey: recency.removeFirst())
            }
        }
        return item
    }

    private func touch(_ id: String) {
        recency.removeAll { $0 == id }
        recency.append(id)
    }
}

public extension HMMediaItem {
    /// Creates a HotMic reference with stable playlist identity `hotmic:<id>`.
    static func hotmicStream(_ id: String) -> Self {
        HMMediaItem(id: "hotmic:\(id)", source: .reference(namespace: "hotmic", id: id),
                    metadata: ["hotmic.namespace": "hotmic", "hotmic.streamID": id])
    }
}
