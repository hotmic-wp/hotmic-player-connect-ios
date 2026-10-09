import Foundation
import HotMicCore
import HotMicPlayerConnect

public extension HotMicItemResolver {
    /// Creates an offline/test resolver with an injected transport. Import HotMicPlayerConnectTesting.
    init(client: any HotMicStreamClient, cacheCapacity: Int = 32) {
        self.init(client: StreamClientBridge(base: client), cacheCapacity: cacheCapacity)
    }
}

public extension HotMicPlaylistSource {
    /// Creates an offline/test playlist with an injected transport. The query is preserved.
    init(client: any HotMicStreamClient, query: HotMicStreamQuery = HotMicStreamQuery(
        includesLive: false, includesScheduled: false, includesVOD: true
    )) {
        self.init(client: StreamClientBridge(base: client), query: query)
    }
}

public extension HotMicInteractionSource {
    /// Creates offline/test engagement. Access on the main actor; retryBaseDelay can accelerate tests.
    convenience init(factory: any HotMicSessionFactory, nextSessionDelay: TimeInterval = 1,
                     retryBaseDelay: TimeInterval = 1) {
        self.init(factory: SessionFactoryBridge(base: factory), nextSessionDelay: nextSessionDelay,
                  retryBaseDelay: retryBaseDelay)
    }
}

private struct StreamClientBridge: _HotMicStreamClient {
    let base: any HotMicStreamClient
    func fetchStream(id: String) async throws -> _HotMicStreamSummary {
        try await base.fetchStream(id: id).runtimeValue
    }
    func fetchStreams(matching query: HotMicStreamQuery) async throws -> _HotMicStreamPage {
        let page = try await base.fetchStreams(matching: query)
        return _HotMicStreamPage(streams: page.streams.map(\.runtimeValue), currentPage: page.currentPage, hasNext: page.hasNext)
    }
}

@MainActor private struct SessionFactoryBridge: _HotMicSessionFactory {
    let base: any HotMicSessionFactory
    func makeSession(streamID: String) -> any _HotMicSession {
        SessionBridge(base: base.makeSession(streamID: streamID))
    }
}

@MainActor private final class SessionBridge: _HotMicSession {
    let base: any HotMicSession
    let events: AsyncStream<_HotMicSessionEvent>
    private let forwarding: Task<Void, Never>
    init(base: any HotMicSession) {
        self.base = base
        let incoming = base.events
        let pair = AsyncStream<_HotMicSessionEvent>.makeStream()
        events = pair.stream
        forwarding = Task { @MainActor in
            for await event in incoming {
                guard !Task.isCancelled else { break }
                pair.continuation.yield(event.runtimeValue)
            }
            pair.continuation.finish()
        }
    }
    deinit { forwarding.cancel() }
    func start() async throws -> _HotMicSessionSnapshot { try await base.start().runtimeValue }
    func stop() async { await base.stop(); forwarding.cancel() }
    func sendChat(_ text: String) async throws -> _HotMicChat { try await base.sendChat(text).runtimeValue }
    func addReaction(_ type: String, to messageID: String) async throws -> _HotMicMessageReaction {
        try await base.addReaction(type, to: messageID).runtimeValue
    }
    func vote(pollID: String, optionID: String) async throws { try await base.vote(pollID: pollID, optionID: optionID) }
}

extension HotMicFixtureStreamSummary {
    var runtimeValue: _HotMicStreamSummary {
        .init(id: id, isVOD: isVOD, vodURL: vodURL, thumbnail: thumbnail, title: title, duration: duration)
    }
}
extension HotMicChat {
    var runtimeValue: _HotMicChat { .init(id: id, author: author, text: text, createdAt: createdAt, avatar: avatar, counts: counts) }
}
extension HotMicMessageReaction {
    var runtimeValue: _HotMicMessageReaction { .init(messageID: messageID, userID: userID, type: type) }
}
extension HotMicFixturePoll {
    var runtimeValue: _HotMicPoll {
        .init(id: id, question: question, createdAt: createdAt, closed: closed, viewerVote: viewerVote,
              options: options.map { .init(id: $0.id, text: $0.text, votes: $0.votes) })
    }
}
extension HotMicSessionSnapshot {
    var runtimeValue: _HotMicSessionSnapshot {
        .init(liveDate: liveDate, duration: duration, userID: userID,
              messages: messages.map(\.runtimeValue), polls: polls.map(\.runtimeValue))
    }
}
extension HotMicSessionEvent {
    var runtimeValue: _HotMicSessionEvent {
        switch self {
        case .connection(let state): return .connection(state)
        case .failed(let error): return .failed(error)
        case .stream(let date, let duration): return .stream(liveDate: date, duration: duration)
        case .ended: return .ended
        case .deleted: return .deleted
        case .chat(let messages, let reactions): return .chat(messages: messages.map(\.runtimeValue), reactions: reactions.map(\.runtimeValue))
        case .messageDeleted(let id): return .messageDeleted(id)
        case .reactionDeleted(let reaction): return .reactionDeleted(reaction.runtimeValue)
        case .poll(let poll): return .poll(poll.runtimeValue)
        case .pollDeleted(let id): return .pollDeleted(id)
        }
    }
}
