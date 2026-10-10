import Foundation
import HotMicCore
import HotMicPlayer

/// Creates fresh, single-use engagement sessions. Access on the main actor.
@MainActor package protocol _HotMicSessionFactory {
    /// Constructs an inert session; networking begins at start(). Main actor.
    func makeSession(streamID: String) -> any _HotMicSession
    /// Item fire membership and comment paging this backend can serve. Defaults to none.
    var itemEngagement: HMEngagementCapabilities { get }
}

extension _HotMicSessionFactory {
    var itemEngagement: HMEngagementCapabilities { [] }
}

/// An injectable single-use Core engagement session. All access is on the main actor.
@MainActor package protocol _HotMicSession: AnyObject {
    /// Events subscribed before start; finish the stream when stopped.
    var events: AsyncStream<_HotMicSessionEvent> { get }
    /// Opens the session and returns its initial snapshot; throw on startup failure.
    func start() async throws -> _HotMicSessionSnapshot
    /// Closes polling and awaits cleanup. Must be idempotent, including after failed start.
    func stop() async
    /// Sends text and returns a server-confirmed message identity.
    func sendChat(_ text: String) async throws -> _HotMicChat
    /// Adds a Core reaction type (like/fire/laugh/anger/sadness) to a message.
    func addReaction(_ type: String, to messageID: String) async throws -> _HotMicMessageReaction
    /// Sets membership in an item reaction count and returns authoritative totals.
    func setItemReaction(_ emoji: String, isReacted: Bool) async throws -> _HotMicItemReaction
    /// Loads newest comments for nil, or older comments for an opaque cursor.
    func comments(before cursor: String?) async throws -> _HotMicCommentPage
    /// Submits the selected poll option; emit a poll event to reconcile the viewer vote.
    func vote(pollID: String, optionID: String) async throws
}

extension _HotMicSession {
    func setItemReaction(_ emoji: String, isReacted: Bool) async throws -> _HotMicItemReaction {
        throw HMInteractionError.unsupportedAction
    }
    func comments(before cursor: String?) async throws -> _HotMicCommentPage {
        throw HMInteractionError.unsupportedAction
    }
}

/// Raw Core chat with wall-clock creation time. Sendable across tasks.
package struct _HotMicChat: Sendable {
    /// Stable server identity.
    package let id: String
    /// Display name of the message author.
    package let author: String
    /// Optional avatar image URL.
    package let avatar: URL?
    /// Display text.
    package let text: String
    /// Server wall-clock creation time.
    package let createdAt: Date
    /// Authoritative totals keyed by player emoji; negative totals are ignored.
    package var counts: [String: Int]
    /// Creates a transport-independent value for an injected session.
    package init(id: String, author: String, text: String, createdAt: Date,
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
package struct _HotMicMessageReaction: Sendable {
    /// The affected server message ID.
    package let messageID: String
    /// The authenticated viewer ID in snapshots, or reacting user ID in reactions.
    package let userID: String
    /// Core reaction type: like, fire, laugh, anger or sadness.
    package let type: String
    /// Creates a transport-independent value for an injected session.
    package init(messageID: String, userID: String, type: String) {
        self.messageID = messageID; self.userID = userID; self.type = type
    }
    init(_ reaction: HotMicChatMessage.Reaction) {
        self.init(messageID: reaction.chatID, userID: reaction.userID, type: reaction.type.rawValue)
    }
}

/// Authoritative item reaction membership. Independent of timed stream reactions.
package struct _HotMicItemReaction: Sendable {
    /// Player emoji, such as fire.
    package let emoji: String
    /// Total memberships, including the viewer.
    package let count: Int
    /// Whether the signed-in viewer belongs to this count.
    package let reactedByViewer: Bool
    /// Creates a transport-independent value.
    package init(emoji: String, count: Int, reactedByViewer: Bool) {
        self.emoji = emoji; self.count = max(0, count); self.reactedByViewer = reactedByViewer
    }
}

/// One page of item comments, separate from media-clock replay.
package struct _HotMicCommentPage: Sendable {
    /// Comments in this page. They are not timeline events.
    package let comments: [_HotMicChat]
    /// Opaque cursor for an older page, or nil at the end.
    package let olderCursor: String?
    /// Authoritative item comment count, when the backend provides one.
    package let totalCount: Int?
    /// Creates a transport-independent page. A nil total leaves the known count unchanged.
    package init(comments: [_HotMicChat], olderCursor: String? = nil, totalCount: Int? = nil) {
        self.comments = comments; self.olderCursor = olderCursor; self.totalCount = totalCount.map { max(0, $0) }
    }
}

/// Raw Core poll state. Sendable across tasks.
package struct _HotMicPoll: Sendable {
    /// A poll option and its authoritative response count. Sendable across tasks.
    package struct Option: Sendable {
        /// Stable server identity.
        package let id: String
        /// Display text.
        package let text: String
        /// Authoritative response count.
        package let votes: Int
        /// Creates a transport-independent value for an injected session.
        package init(id: String, text: String, votes: Int) { self.id = id; self.text = text; self.votes = votes }
    }
    /// Stable server identity.
    package let id: String
    /// Poll question.
    package let question: String
    /// Server wall-clock creation time.
    package let createdAt: Date
    /// Whether the poll is closed; Core supplies no closing timestamp.
    package let closed: Bool
    /// The viewer’s selected option ID, if known.
    package let viewerVote: String?
    /// Poll options in display order.
    package let options: [Option]
    /// Creates a transport-independent value for an injected session.
    package init(id: String, question: String, createdAt: Date, closed: Bool = false,
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
package struct _HotMicSessionSnapshot: Sendable {
    /// Stream live origin used to position VOD history; nil means unknown.
    package let liveDate: Date?
    /// Optional VOD duration in seconds; nil means unknown.
    package let duration: TimeInterval?
    /// The authenticated viewer ID in snapshots, or reacting user ID in reactions.
    package let userID: String
    /// Raw chat history returned at startup; not guaranteed to cover the full VOD.
    package let messages: [_HotMicChat]
    /// Raw polls returned at startup.
    package let polls: [_HotMicPoll]
    /// Known item reaction totals at startup. Empty means the backend has none.
    package let itemReactions: [_HotMicItemReaction]
    /// Known item comment count at startup, or nil when unknown.
    package let commentCount: Int?
    /// Creates a transport-independent value for an injected session.
    package init(liveDate: Date?, duration: TimeInterval?, userID: String,
                messages: [_HotMicChat] = [], polls: [_HotMicPoll] = [],
                itemReactions: [_HotMicItemReaction] = [], commentCount: Int? = nil) {
        self.liveDate = liveDate; self.duration = duration; self.userID = userID
        self.messages = messages; self.polls = polls
        self.itemReactions = itemReactions; self.commentCount = commentCount
    }
}

/// Core session updates projected for the adapter. Sendable across tasks.
package enum _HotMicSessionEvent: Sendable {
    /// Engagement connectivity changed independently of playback.
    case connection(HotMicInteractionSource.ConnectionState)
    /// Session startup failed; transient errors may create a fresh session after backoff.
    case failed(HotMicError)
    /// Stream timing changed; retained history is remapped when timing becomes available.
    case stream(liveDate: Date?, duration: TimeInterval?)
    /// The stream ended; the adapter closes the session.
    case ended
    /// The stream was deleted; the adapter closes the session.
    case deleted
    /// New messages and reaction additions, including server echoes.
    case chat(messages: [_HotMicChat], reactions: [_HotMicMessageReaction])
    /// A moderator deleted a message by server ID.
    case messageDeleted(String)
    /// A reaction identity was removed.
    case reactionDeleted(_HotMicMessageReaction)
    /// A poll was created or updated.
    case poll(_HotMicPoll)
    /// A moderator deleted a poll by server ID.
    case pollDeleted(String)
    /// Authoritative item reaction membership changed.
    case itemReaction(_HotMicItemReaction)
    /// An item comment arrived outside the media-clock replay timeline.
    case liveComment(_HotMicChat, totalCount: Int?)
}

@MainActor struct LiveHotMicSessionFactory: _HotMicSessionFactory {
    let client: HotMicClient
    func makeSession(streamID: String) -> any _HotMicSession {
        LiveHotMicSession(session: client.makeStreamSession(streamID: streamID))
    }
}

@MainActor private final class LiveHotMicSession: _HotMicSession {
    let session: HotMicStreamSession
    let events: AsyncStream<_HotMicSessionEvent>
    private let forwarding: Task<Void, Never>
    init(session: HotMicStreamSession) {
        self.session = session
        // Subscribe before start(), including the Core stream (not just our projection).
        let incoming = session.events
        let pair = AsyncStream<_HotMicSessionEvent>.makeStream()
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
    func start() async throws -> _HotMicSessionSnapshot {
        let snapshot = try await session.start()
        return _HotMicSessionSnapshot(liveDate: snapshot.stream.liveDate, duration: snapshot.stream.duration,
                                   userID: snapshot.user.id, messages: snapshot.chatMessages.map(_HotMicChat.init),
                                   polls: snapshot.polls.map(_HotMicPoll.init))
    }
    func stop() async { await session.stop(); forwarding.cancel() }
    func sendChat(_ text: String) async throws -> _HotMicChat { _HotMicChat(try await session.chat.sendChatMessage(text)) }
    func addReaction(_ type: String, to messageID: String) async throws -> _HotMicMessageReaction {
        _HotMicMessageReaction(try await session.chat.addChatMessageReaction(.init(rawValue: type), to: messageID))
    }
    func vote(pollID: String, optionID: String) async throws {
        try await session.polls.submitResponse(pollID: pollID, optionID: optionID)
    }
    /// HotMicCore 1.0.2 has no stream or item reaction membership API.
    func setItemReaction(_ emoji: String, isReacted: Bool) async throws -> _HotMicItemReaction {
        throw HMInteractionError.unsupportedAction
    }
    /// HotMicCore 1.0.2 returns one snapshot chat list plus live batches, with no cursor or comment count.
    func comments(before cursor: String?) async throws -> _HotMicCommentPage {
        throw HMInteractionError.unsupportedAction
    }
    private static func map(_ event: HotMicStreamSession.Event) -> _HotMicSessionEvent? {
        switch event {
        case .connectionChanged(.connected): return .connection(.connected)
        case .connectionChanged(.reconnecting(let attempt)): return .connection(.reconnecting(attempt: attempt))
        case .connectionChanged(.disconnected): return .connection(.disconnected)
        case .stateChanged(.failed(let error)): return .failed(error)
        case .streamUpdated(let stream): return .stream(liveDate: stream.liveDate, duration: stream.duration)
        case .streamEnded: return .ended
        case .streamDeleted: return .deleted
        case .chatBatchReceived(let batch): return .chat(messages: batch.messages.map(_HotMicChat.init), reactions: batch.reactions.map(_HotMicMessageReaction.init))
        case .chatMessageDeleted(let id): return .messageDeleted(id)
        case .chatMessageReactionDeleted(let id, let user, let type):
            return .reactionDeleted(.init(messageID: id, userID: user, type: type.rawValue))
        case .pollCreated(let poll), .pollUpdated(let poll): return .poll(_HotMicPoll(poll))
        case .pollDeleted(let id): return .pollDeleted(id)
        case .stateChanged, .participantsUpdated: return nil
        @unknown default: return nil
        }
    }
}
