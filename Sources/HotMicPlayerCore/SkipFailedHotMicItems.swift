import HotMicPlayer

public extension HMPlayer {
    /// Interim host-side policy for HotMicPlayer 0.3: removes HotMic references
    /// rejected as non-VOD or missing a VOD URL, including failed upcoming items.
    /// Transport/authentication failures retain the player's retry behavior.
    /// Call before starting playback. Retain the task and cancel it on dismissal.
    /// This helper will be deprecated when the player gains a native failure policy.
    @MainActor
    func skipFailedHotMicItems() -> Task<Void, Never> {
        // Subscribe synchronously so mutations immediately after this call are seen.
        let stream = events
        return Task { @MainActor [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard let item = Self.terminalHotMicItem(in: event),
                      self.items.contains(item) else { continue }
                // Removal also handles the final/only entry, unlike next(). Exact
                // item equality prevents a stale event removing a replaced entry.
                self.remove(ids: [item.id])
            }
        }
    }

    internal static func terminalHotMicItem(in event: HMPlayerEvent) -> HMMediaItem? {
        guard case let .error(item?, .resolution(message)) = event,
              case let .reference(namespace, id) = item.source, namespace == "hotmic" else { return nil }
        // The player erases the underlying error type to a description. Match only
        // this adapter's two terminal messages, including the reference's own ID.
        let terminal = [HotMicPlayerCoreError.notVOD(streamID: id), .missingVODURL(streamID: id)]
        return terminal.contains { $0.errorDescription == message } ? item : nil
    }
}
