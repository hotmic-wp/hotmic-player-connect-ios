import Foundation
import HotMicCore

/// Creates fresh, single-use engagement sessions. Access on the main actor.
@MainActor public protocol CoreSessionFactory {
    /// Constructs an inert session; networking begins at start(). Main actor.
    func makeSession(streamID: String) -> any CoreSession
}

/// An injectable single-use Core engagement session. All access is on the main actor.
@MainActor public protocol CoreSession: AnyObject {
    /// Events subscribed before start; finish the stream when stopped.
    var events: AsyncStream<CoreSessionEvent> { get }
    /// Opens the session and returns its initial snapshot; throw on startup failure.
    func start() async throws -> CoreSessionSnapshot
    /// Closes polling and awaits cleanup. Must be idempotent, including after failed start.
    func stop() async
    /// Sends text and returns a server-confirmed message identity.
    func sendChat(_ text: String) async throws -> CoreChat
    /// Adds a Core reaction type (like/fire/laugh/anger/sadness) to a message.
    func addReaction(_ type: String, to messageID: String) async throws -> CoreMessageReaction
    /// Submits the selected poll option; emit a poll event to reconcile the viewer vote.
    func vote(pollID: String, optionID: String) async throws
}

/// Raw Core chat with wall-clock creation time. Sendable across tasks.
public struct CoreChat: Sendable {
    /// Stable server identity.
    public let id: String
    /// Display name of the message author.
    public let author: String
    /// Optional avatar image URL.
    public let avatar: URL?
    /// Display text.
    public let text: String
    /// Server wall-clock creation time.
    public let createdAt: Date
    /// Authoritative totals keyed by player emoji; negative totals are ignored.
    public var counts: [String: Int]
    /// Creates a transport-independent value for an injected session.
    public init(id: String, author: String, text: String, createdAt: Date,
                avatar: URL? = nil, counts: [String: Int] = [:]) {
        self.id = id; self.author = author; self.text = text; self.createdAt = createdAt
        self.avatar = avatar; self.counts = counts
    }
    init(_ message: HotMicChatMessage) {
        self.init(id: message.id, author: message.userName, text: message.message,
                  createdAt: message.createdAt, avatar: message.profilePic,
                  counts: ["👍": message.likeCount, "🔥": message.fireCount, "😆": message.laughCount,
                           "😡": message.angerCount, "😢": message.sadnessCount])
    }
}

/// Message reaction identity supplied by Core. Sendable across tasks.
public struct CoreMessageReaction: Sendable {
    /// The affected server message ID.
    public let messageID: String
    /// The authenticated viewer ID in snapshots, or reacting user ID in reactions.
    public let userID: String
    /// Core reaction type: like, fire, laugh, anger or sadness.
    public let type: String
    /// Creates a transport-independent value for an injected session.
    public init(messageID: String, userID: String, type: String) {
        self.messageID = messageID; self.userID = userID; self.type = type
    }
    init(_ reaction: HotMicChatMessage.Reaction) {
        self.init(messageID: reaction.chatID, userID: reaction.userID, type: reaction.type.rawValue)
    }
}

/// Raw Core poll state. Sendable across tasks.
public struct CorePoll: Sendable {
    /// A poll option and its authoritative response count. Sendable across tasks.
    public struct Option: Sendable {
        /// Stable server identity.
        public let id: String
        /// Display text.
        public let text: String
        /// Authoritative response count.
        public let votes: Int
        /// Creates a transport-independent value for an injected session.
        public init(id: String, text: String, votes: Int) { self.id = id; self.text = text; self.votes = votes }
    }
    /// Stable server identity.
    public let id: String
    /// Poll question.
    public let question: String
    /// Server wall-clock creation time.
    public let createdAt: Date
    /// Whether the poll is closed; Core supplies no closing timestamp.
    public let closed: Bool
    /// The viewer’s selected option ID, if known.
    public let viewerVote: String?
    /// Poll options in display order.
    public let options: [Option]
    /// Creates a transport-independent value for an injected session.
    public init(id: String, question: String, createdAt: Date, closed: Bool = false,
                viewerVote: String? = nil, options: [Option]) {
        self.id = id; self.question = question; self.createdAt = createdAt
        self.closed = closed; self.viewerVote = viewerVote; self.options = options
    }
    init(_ poll: HotMicPoll) {
        self.init(id: poll.id, question: poll.question ?? "", createdAt: poll.createdAt,
                  closed: poll.closed, viewerVote: poll.myAnswer,
                  options: poll.options.map { Option(id: $0.id, text: $0.answer, votes: $0.responses) })
    }
}

/// Initial stream timing, viewer and history for a session. Sendable across tasks.
public struct CoreSessionSnapshot: Sendable {
    /// Stream live origin used to position VOD history; nil means unknown.
    public let liveDate: Date?
    /// Optional VOD duration in seconds; nil means unknown.
    public let duration: TimeInterval?
    /// The authenticated viewer ID in snapshots, or reacting user ID in reactions.
    public let userID: String
    /// Raw chat history returned at startup; not guaranteed to cover the full VOD.
    public let messages: [CoreChat]
    /// Raw polls returned at startup.
    public let polls: [CorePoll]
    /// Creates a transport-independent value for an injected session.
    public init(liveDate: Date?, duration: TimeInterval?, userID: String,
                messages: [CoreChat] = [], polls: [CorePoll] = []) {
        self.liveDate = liveDate; self.duration = duration; self.userID = userID
        self.messages = messages; self.polls = polls
    }
}

/// Core session updates projected for the adapter. Sendable across tasks.
public enum CoreSessionEvent: Sendable {
    /// Engagement connectivity changed independently of playback.
    case connection(CoreInteractionSource.ConnectionState)
    /// Session startup failed; transient errors may create a fresh session after backoff.
    case failed(HotMicError)
    /// Stream timing changed; retained history is remapped when timing becomes available.
    case stream(liveDate: Date?, duration: TimeInterval?)
    /// The stream ended; the adapter closes the session.
    case ended
    /// The stream was deleted; the adapter closes the session.
    case deleted
    /// New messages and reaction additions, including server echoes.
    case chat(messages: [CoreChat], reactions: [CoreMessageReaction])
    /// A moderator deleted a message by server ID.
    case messageDeleted(String)
    /// A reaction identity was removed.
    case reactionDeleted(CoreMessageReaction)
    /// A poll was created or updated.
    case poll(CorePoll)
    /// A moderator deleted a poll by server ID.
    case pollDeleted(String)
}

@MainActor struct LiveCoreSessionFactory: CoreSessionFactory {
    let client: HotMicClient
    func makeSession(streamID: String) -> any CoreSession {
        LiveCoreSession(session: client.makeStreamSession(streamID: streamID))
    }
}

@MainActor private final class LiveCoreSession: CoreSession {
    let session: HotMicStreamSession
    let events: AsyncStream<CoreSessionEvent>
    private let forwarding: Task<Void, Never>
    init(session: HotMicStreamSession) {
        self.session = session
        // Subscribe before start(), including the Core stream (not just our projection).
        let incoming = session.events
        let pair = AsyncStream<CoreSessionEvent>.makeStream()
        events = pair.stream
        forwarding = Task { @MainActor in
            for await event in incoming {
                guard !Task.isCancelled else { break }
                if let mapped = Self.map(event) { pair.continuation.yield(mapped) }
            }
            pair.continuation.finish()
        }
    }
    deinit { forwarding.cancel() }
    func start() async throws -> CoreSessionSnapshot {
        let snapshot = try await session.start()
        return CoreSessionSnapshot(liveDate: snapshot.stream.liveDate, duration: snapshot.stream.duration,
                                   userID: snapshot.user.id, messages: snapshot.chatMessages.map(CoreChat.init),
                                   polls: snapshot.polls.map(CorePoll.init))
    }
    func stop() async { await session.stop(); forwarding.cancel() }
    func sendChat(_ text: String) async throws -> CoreChat { CoreChat(try await session.chat.sendChatMessage(text)) }
    func addReaction(_ type: String, to messageID: String) async throws -> CoreMessageReaction {
        CoreMessageReaction(try await session.chat.addChatMessageReaction(.init(rawValue: type), to: messageID))
    }
    func vote(pollID: String, optionID: String) async throws {
        try await session.polls.submitResponse(pollID: pollID, optionID: optionID)
    }
    private static func map(_ event: HotMicStreamSession.Event) -> CoreSessionEvent? {
        switch event {
        case .connectionChanged(.connected): return .connection(.connected)
        case .connectionChanged(.reconnecting(let attempt)): return .connection(.reconnecting(attempt: attempt))
        case .connectionChanged(.disconnected): return .connection(.disconnected)
        case .stateChanged(.failed(let error)): return .failed(error)
        case .streamUpdated(let stream): return .stream(liveDate: stream.liveDate, duration: stream.duration)
        case .streamEnded: return .ended
        case .streamDeleted: return .deleted
        case .chatBatchReceived(let batch): return .chat(messages: batch.messages.map(CoreChat.init), reactions: batch.reactions.map(CoreMessageReaction.init))
        case .chatMessageDeleted(let id): return .messageDeleted(id)
        case .chatMessageReactionDeleted(let id, let user, let type):
            return .reactionDeleted(.init(messageID: id, userID: user, type: type.rawValue))
        case .pollCreated(let poll), .pollUpdated(let poll): return .poll(CorePoll(poll))
        case .pollDeleted(let id): return .pollDeleted(id)
        case .stateChanged, .participantsUpdated: return nil
        @unknown default: return nil
        }
    }
}
