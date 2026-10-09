import XCTest
import HotMicCore
import HotMicPlayer
@testable import HotMicPlayerCore

private actor FakeClient: CoreStreamClient {
    var streamCalls = 0
    var requestedPages: [Int] = []
    var queries: [HotMicStreamQuery] = []
    let summaries: [String: CoreStreamSummary]
    let pages: [Int: CoreStreamPage]
    let fails: Bool

    init(summaries: [CoreStreamSummary] = [], pages: [Int: CoreStreamPage] = [:], fails: Bool = false) {
        self.summaries = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
        self.pages = pages
        self.fails = fails
    }
    func fetchStream(id: String) async throws -> CoreStreamSummary {
        streamCalls += 1
        if fails { throw URLError(.notConnectedToInternet) }
        return summaries[id]!
    }
    func fetchStreams(matching query: HotMicStreamQuery) async throws -> CoreStreamPage {
        requestedPages.append(query.page); queries.append(query)
        return pages[query.page]!
    }
}

final class CoreStreamsTests: XCTestCase {
    private let url = URL(string: "https://example.com/replay.m3u8")!
    private func vod(_ id: String) -> CoreStreamSummary {
        CoreStreamSummary(id: id, isVOD: true, vodURL: url,
                          thumbnail: URL(string: "https://example.com/poster.jpg"), title: "Replay", duration: 42)
    }

    func testSummaryMappingAndTerminalErrors() throws {
        let summary = vod("one")
        let resolved = try summary.resolvedItem()
        XCTAssertEqual(resolved.url, url)
        XCTAssertEqual(resolved.format, .auto)
        XCTAssertEqual(resolved.poster, summary.thumbnail)
        XCTAssertEqual(resolved.title, "Replay")
        XCTAssertEqual(resolved.duration, 42)
        let item = try summary.playlistItem()
        XCTAssertEqual(item.id, HMMediaItem.hotmicStream("one").id)
        XCTAssertEqual(item.source, .url(url, format: .auto))
        XCTAssertEqual(item.posterURL, resolved.poster)
        XCTAssertEqual(item.title, resolved.title)
        XCTAssertEqual(item.durationHint, 42)
        for (summary, expected) in [
            (CoreStreamSummary(id: "live", isVOD: false, vodURL: url), HotMicPlayerCoreError.notVOD(streamID: "live")),
            (CoreStreamSummary(id: "missing", isVOD: true, vodURL: nil), .missingVODURL(streamID: "missing"))
        ] {
            XCTAssertThrowsError(try summary.resolvedItem()) { XCTAssertEqual($0 as? HotMicPlayerCoreError, expected) }
        }
    }

    func testResolverCacheEvictionAndTypedErrorPaths() async throws {
        let client = FakeClient(summaries: [vod("one"), vod("two"),
            CoreStreamSummary(id: "live", isVOD: false, vodURL: url),
            CoreStreamSummary(id: "missing", isVOD: true, vodURL: nil)])
        let resolver = CoreItemResolver(client: client, cacheCapacity: 1)
        let one = HMMediaItem.Reference(namespace: "hotmic", id: "one")
        _ = try await resolver.resolve(one)
        _ = try await resolver.resolve(one)
        var calls = await client.streamCalls
        XCTAssertEqual(calls, 1)
        _ = try await resolver.resolve(.init(namespace: "hotmic", id: "two"))
        _ = try await resolver.resolve(one)
        calls = await client.streamCalls
        XCTAssertEqual(calls, 3)
        for (namespace, id, expected) in [
            ("other", "one", HotMicPlayerCoreError.unsupportedNamespace("other")),
            ("hotmic", "live", .notVOD(streamID: "live")),
            ("hotmic", "missing", .missingVODURL(streamID: "missing"))
        ] {
            do { _ = try await resolver.resolve(.init(namespace: namespace, id: id)); XCTFail("Expected typed error") }
            catch { XCTAssertEqual(error as? HotMicPlayerCoreError, expected) }
        }
        calls = await client.streamCalls
        XCTAssertEqual(calls, 5, "Unsupported namespaces must not fetch")
    }

    func testTransportErrorsArePropagated() async {
        let resolver = CoreItemResolver(client: FakeClient(fails: true))
        do { _ = try await resolver.resolve(.init(namespace: "hotmic", id: "one")); XCTFail("Expected transport error") }
        catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
    }

    func testPagingFiltersWithoutLookupAndStopsAtHasNextFalse() async throws {
        let client = FakeClient(pages: [
            1: CoreStreamPage(streams: [CoreStreamSummary(id: "live", isVOD: false, vodURL: url),
                                      CoreStreamSummary(id: "missing", isVOD: true, vodURL: nil)], currentPage: 1, hasNext: true),
            2: CoreStreamPage(streams: [vod("one"), vod("one")], currentPage: 2, hasNext: false)
        ])
        let source = CorePlaylistSource(client: client)
        let first = try await source.loadPage(cursor: nil)
        XCTAssertTrue(first.items.isEmpty)
        XCTAssertEqual(first.nextCursor, "2", "Filtering a whole page must not end the feed")
        let last = try await source.loadPage(cursor: first.nextCursor)
        XCTAssertNil(last.nextCursor)
        XCTAssertEqual(last.items.map(\.id), ["hotmic:one", "hotmic:one"], "Player owns de-duplication")
        let calls = await client.streamCalls
        let pages = await client.requestedPages
        let query = await client.queries[0]
        XCTAssertEqual(calls, 0, "Resolved summary URLs must not trigger by-ID requests")
        XCTAssertEqual(pages, [1, 2])
        XCTAssertFalse(query.includesLive); XCTAssertFalse(query.includesScheduled); XCTAssertTrue(query.includesVOD)
    }

    func testQueryPreservationAndMalformedCursors() async throws {
        let client = FakeClient(pages: [4: CoreStreamPage(streams: [], currentPage: 4, hasNext: false)])
        let query = HotMicStreamQuery(includesLive: true, includesScheduled: false, includesVOD: true,
                                      userID: "creator", page: 4, limit: 7)
        let source = CorePlaylistSource(client: client, query: query)
        _ = try await source.loadPage(cursor: nil)
        let received = await client.queries[0]
        XCTAssertEqual(received.page, 4); XCTAssertEqual(received.limit, 7); XCTAssertEqual(received.userID, "creator")
        XCTAssertTrue(received.includesLive); XCTAssertFalse(received.includesScheduled)
        for cursor in ["garbage", "0", "-1"] {
            do { _ = try await source.loadPage(cursor: cursor); XCTFail("Expected invalid cursor") }
            catch { XCTAssertEqual(error as? HotMicPlayerCoreError, .invalidCursor(cursor)) }
        }
        let pages = await client.requestedPages
        XCTAssertEqual(pages, [4])
    }

    @MainActor
    func testSkipPolicyRecognizesOnlyMatchingTerminalHotMicErrors() {
        let item = HMMediaItem.hotmicStream("bad")
        let terminal = HotMicPlayerCoreError.notVOD(streamID: "bad").localizedDescription
        XCTAssertEqual(HMPlayer.terminalHotMicItem(in: .error(item: item, kind: .resolution(terminal))), item)
        let missing = HotMicPlayerCoreError.missingVODURL(streamID: "bad").localizedDescription
        XCTAssertEqual(HMPlayer.terminalHotMicItem(in: .error(item: item, kind: .resolution(missing))), item)
        for event in [
            HMPlayerEvent.error(item: item, kind: .resolution("Network unavailable")),
            .error(item: item, kind: .playback(terminal)),
            .error(item: .hotmicStream("different"), kind: .resolution(terminal)),
            .error(item: .reference("other", id: "bad"), kind: .resolution(terminal)),
            .error(item: HMMediaItem(id: item.id, url: url), kind: .resolution(terminal)),
            .error(item: nil, kind: .resolution(terminal))
        ] { XCTAssertNil(HMPlayer.terminalHotMicItem(in: event)) }
    }

    @MainActor
    func testSkipHelperRemovesOnlyFailedEntryAndHandlesEmptyPlaylist() async throws {
        let client = FakeClient(summaries: [CoreStreamSummary(id: "bad", isVOD: false, vodURL: nil)])
        let player = HMPlayer(resolver: CoreItemResolver(client: client))
        let task = player.skipFailedHotMicItems()
        defer { task.cancel(); player.teardown() }
        let subscription = player.events
        let errorObserved = Task { @MainActor in
            for await event in subscription {
                if HMPlayer.terminalHotMicItem(in: event) != nil { return true }
            }
            return false
        }
        defer { errorObserved.cancel() }
        player.replaceAll([.hotmicStream("bad")])
        // Bounded wait for native transport startup + resolver completion; no media URL is fetched.
        for _ in 0..<200 {
            if player.items.isEmpty { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(player.items.isEmpty)
        XCTAssertNil(player.currentItem)
        if player.items.isEmpty { let observed = await errorObserved.value; XCTAssertTrue(observed) }
    }
}
