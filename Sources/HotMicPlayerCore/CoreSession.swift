import Foundation
import HotMicCore

// Project the binary's initializer-less values at this one boundary. This is
// Testing SPI for the sample/fakes, not another partner session API.
@_spi(Testing) @MainActor public protocol CoreSessionFactory {
    func makeSession(streamID: String) -> any CoreSession
}

@_spi(Testing) @MainActor public protocol CoreSession: AnyObject {
    var events: AsyncStream<CoreSessionEvent> { get }
    func start() async throws -> CoreSessionSnapshot
    func stop() async
    func sendChat(_ text: String) async throws -> CoreChat
    func addReaction(_ type: String, to messageID: String) async throws -> CoreMessageReaction
    func vote(pollID: String, optionID: String) async throws
}

@_spi(Testing) public struct CoreChat: Sendable {
    public let id: String
    public let author: String
    public let avatar: URL?
    public let text: String
    public let createdAt: Date
    public var counts: [String: Int]
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

@_spi(Testing) public struct CoreMessageReaction: Sendable {
    public let messageID: String
    public let userID: String
    public let type: String
    public init(messageID: String, userID: String, type: String) {
        self.messageID = messageID; self.userID = userID; self.type = type
    }
    init(_ reaction: HotMicChatMessage.Reaction) {
        self.init(messageID: reaction.chatID, userID: reaction.userID, type: reaction.type.rawValue)
    }
}

@_spi(Testing) public struct CorePoll: Sendable {
    public struct Option: Sendable {
        public let id: String
        public let text: String
        public let votes: Int
        public init(id: String, text: String, votes: Int) { self.id = id; self.text = text; self.votes = votes }
    }
    public let id: String
    public let question: String
    public let createdAt: Date
    public let closed: Bool
    public let viewerVote: String?
    public let options: [Option]
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

@_spi(Testing) public struct CoreSessionSnapshot: Sendable {
    public let liveDate: Date?
    public let duration: TimeInterval?
    public let userID: String
    public let messages: [CoreChat]
    public let polls: [CorePoll]
    public init(liveDate: Date?, duration: TimeInterval?, userID: String,
                messages: [CoreChat] = [], polls: [CorePoll] = []) {
        self.liveDate = liveDate; self.duration = duration; self.userID = userID
        self.messages = messages; self.polls = polls
    }
}

@_spi(Testing) public enum CoreSessionEvent: Sendable {
    case connection(CoreInteractionSource.ConnectionState)
    case failed
    case stream(liveDate: Date?, duration: TimeInterval?)
    case ended, deleted
    case chat(messages: [CoreChat], reactions: [CoreMessageReaction])
    case messageDeleted(String)
    case reactionDeleted(CoreMessageReaction)
    case poll(CorePoll)
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
        case .stateChanged(.failed): return .failed
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
        }
    }
}
