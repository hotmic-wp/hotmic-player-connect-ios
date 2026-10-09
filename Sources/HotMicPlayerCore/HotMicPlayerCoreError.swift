import Foundation

/// Adapter errors. Core transport/authentication errors are propagated unchanged.
public enum HotMicPlayerCoreError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedNamespace(String)
    case notVOD(streamID: String)
    case missingVODURL(streamID: String)
    case invalidCursor(String)
    case invalidPagination

    /// Terminal playback messages are also recognized by the interim skip helper.
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
