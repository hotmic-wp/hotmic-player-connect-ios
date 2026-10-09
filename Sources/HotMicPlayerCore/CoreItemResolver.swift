import Foundation
import HotMicCore
import HotMicPlayer

/// Resolves `hotmic` references to VOD. Successful results use a bounded in-memory
/// LRU cache for 60 seconds. The player owns request coalescing and retries.
public actor CoreItemResolver: HMItemResolver {
    private let client: any CoreStreamClient
    private let cacheCapacity: Int
    private var cache: [String: (item: HMResolvedItem, expires: TimeInterval)] = [:]
    private var recency: [String] = []
    // Typed outcomes bridge player 0.3's string-only resolution event. Keep at
    // most its event-buffer capacity; a new attempt clears an earlier outcome.
    private var terminalFailures: [String: HotMicPlayerCoreError] = [:]
    private var failureRecency: [String] = []

    /// Creates a resolver sharing the host's authenticated Core client.
    /// Set capacity to zero to disable the adapter cache.
    public init(client: HotMicClient, cacheCapacity: Int = 32) {
        self.init(client: LiveCoreStreamClient(client: client), cacheCapacity: cacheCapacity)
    }

    @_spi(Testing) public init(client: any CoreStreamClient, cacheCapacity: Int = 32) {
        self.client = client
        self.cacheCapacity = max(0, cacheCapacity)
    }

    public func resolve(_ ref: HMMediaItem.Reference) async throws -> HMResolvedItem {
        try Task.checkCancellation()
        guard ref.namespace == "hotmic" else {
            throw HotMicPlayerCoreError.unsupportedNamespace(ref.namespace)
        }
        clearTerminalFailure(ref.id)
        if let entry = cache[ref.id], entry.expires > ProcessInfo.processInfo.systemUptime {
            touch(ref.id)
            return entry.item
        }
        let summary: CoreStreamSummary
        do {
            summary = try await client.fetchStream(id: ref.id)
            try Task.checkCancellation()
        } catch {
            clearTerminalFailure(ref.id)
            throw error
        }
        let item: HMResolvedItem
        do {
            item = try summary.resolvedItem()
        } catch let error as HotMicPlayerCoreError {
            switch error {
            case .notVOD, .missingVODURL:
                clearTerminalFailure(ref.id)
                terminalFailures[ref.id] = error
                failureRecency.append(ref.id)
                while failureRecency.count > 256 {
                    terminalFailures.removeValue(forKey: failureRecency.removeFirst())
                }
            default: break
            }
            throw error
        }
        clearTerminalFailure(ref.id)
        if cacheCapacity > 0 {
            cache[ref.id] = (item, ProcessInfo.processInfo.systemUptime + 60)
            touch(ref.id)
            while recency.count > cacheCapacity {
                cache.removeValue(forKey: recency.removeFirst())
            }
        }
        return item
    }

    func terminalFailure(for id: String) -> HotMicPlayerCoreError? {
        terminalFailures[id]
    }

    private func clearTerminalFailure(_ id: String) {
        terminalFailures[id] = nil
        failureRecency.removeAll { $0 == id }
    }

    private func touch(_ id: String) {
        recency.removeAll { $0 == id }
        recency.append(id)
    }
}

public extension HMMediaItem {
    /// Creates a HotMic reference with stable playlist identity `hotmic:<id>`.
    static func hotmicStream(_ id: String) -> Self {
        .reference("hotmic", id: id)
    }
}
