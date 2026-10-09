import Foundation

/// Adapter errors. Core transport/authentication errors are propagated unchanged.
public enum HotMicPlayerCoreError: Error, Equatable, Sendable, LocalizedError {
    /// The reference namespace is not `hotmic`.
    case unsupportedNamespace(String)
    /// The stream is live or scheduled, rather than recorded VOD.
    case notVOD(streamID: String)
    /// A VOD stream has no playable URL.
    case missingVODURL(streamID: String)
    /// A page cursor is malformed or nonpositive.
    case invalidCursor(String)
    /// The backend page failed to advance safely.
    case invalidPagination

    /// Human-readable validation error description.
    public var errorDescription: String? {
        switch self {
        case .unsupportedNamespace(let namespace):
            return "Unsupported stream namespace: \(namespace)."
        case .notVOD(let id):
            return "HotMicPlayerCore.notVOD: Stream \(id) is not VOD."
        case .missingVODURL(let id):
            return "HotMicPlayerCore.missingVODURL: Stream \(id) has no VOD URL."
        case .invalidCursor(let cursor):
            return "Invalid HotMic playlist cursor: \(cursor)."
        case .invalidPagination:
            return "HotMic pagination did not advance."
        }
    }
}
