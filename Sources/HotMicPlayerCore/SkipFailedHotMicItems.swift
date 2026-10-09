import HotMicPlayer

public extension HMPlayer {
    /// Interim host-side policy for HotMicPlayer 0.3: removes HotMic references
    /// rejected as non-VOD or missing a VOD URL, including failed upcoming items.
    /// Transport/authentication failures retain the player's retry behavior.
    /// Pass the same resolver used by the player, before starting playback.
    /// Retain the task and cancel it on dismissal.
    /// Deprecated: HotMicPlayer has a native failedItemPolicy since 0.3.1.
    @available(*, deprecated, message: "Use HMPlayerConfiguration.failedItemPolicy (default: .skip) instead.")
    @MainActor
    func skipFailedHotMicItems(using resolver: CoreItemResolver) -> Task<Void, Never> {
        // Subscribe synchronously so mutations immediately after this call are seen.
        let stream = events
        return Task { @MainActor [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard let item = await Self.terminalHotMicItem(in: event, using: resolver),
                      self.items.contains(item) else { continue }
                // Removal also handles the final/only entry, unlike next(). Exact
                // item equality prevents a stale event removing a replaced entry.
                self.remove(ids: [item.id])
            }
        }
    }

    @_spi(Testing)
    static func terminalHotMicItem(in event: HMPlayerEvent, using resolver: CoreItemResolver) async -> HMMediaItem? {
        guard case let .error(item?, .resolution) = event,
              case let .reference(namespace, id) = item.source, namespace == "hotmic",
              let failure = await resolver.terminalFailure(for: id) else { return nil }
        // Player 0.3 erases the thrown error type. Consult the same resolver's
        // typed outcome, never the event's localized description.
        switch failure {
        case .notVOD(let streamID), .missingVODURL(let streamID):
            return streamID == id ? item : nil
        default:
            return nil
        }
    }
}
