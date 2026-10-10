import XCTest
import HotMicCore
import HotMicPlayer
@testable import HotMicPlayerConnect
@testable import HotMicPlayerConnectTesting

private actor FakeClient: HotMicStreamClient {
    var streamCalls = 0
    var requestedPages: [Int] = []
    var queries: [HotMicStreamQuery] = []
    let summaries: [String: HotMicFixtureStreamSummary]
    let pages: [Int: HotMicFixtureStreamPage]
    var fails: Bool

    init(summaries: [HotMicFixtureStreamSummary] = [], pages: [Int: HotMicFixtureStreamPage] = [:], fails: Bool = false) {
        self.summaries = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
        self.pages = pages
        self.fails = fails
    }
    func setFails(_ fails: Bool) { self.fails = fails }

    func fetchStream(id: String) async throws -> HotMicFixtureStreamSummary {
        streamCalls += 1
        if fails { throw URLError(.notConnectedToInternet) }
        return summaries[id]!
    }
    func fetchStreams(matching query: HotMicStreamQuery) async throws -> HotMicFixtureStreamPage {
        requestedPages.append(query.page); queries.append(query)
        return pages[query.page]!
    }
}

final class HotMicStreamsTests: XCTestCase {
    private let url = URL(string: "https://example.com/replay.m3u8")!
    private func vod(_ id: String) -> HotMicFixtureStreamSummary {
        HotMicFixtureStreamSummary(id: id, isVOD: true, vodURL: url,
                          thumbnail: URL(string: "https://example.com/poster.jpg"), title: "Replay", duration: 42)
    }

    func testSummaryMappingAndTerminalErrors() throws {
        let summary = vod("one")
        let resolved = try summary.runtimeValue.resolvedItem()
        XCTAssertEqual(resolved.url, url)
        XCTAssertEqual(resolved.format, .auto)
        XCTAssertEqual(resolved.poster, summary.thumbnail)
        XCTAssertEqual(resolved.title, "Replay")
        XCTAssertEqual(resolved.duration, 42)
        let item = try summary.runtimeValue.playlistItem()
        XCTAssertEqual(item.id, HMMediaItem.hotmicStream("one").id)
        XCTAssertEqual(item.source, .url(url, format: .auto))
        XCTAssertEqual(item.posterURL, resolved.poster)
        XCTAssertEqual(item.title, resolved.title)
        XCTAssertEqual(item.durationHint, 42)
        for (summary, expected) in [
            (HotMicFixtureStreamSummary(id: "live", isVOD: false, vodURL: url), HotMicPlayerConnectError.notVOD(streamID: "live")),
            (HotMicFixtureStreamSummary(id: "missing", isVOD: true, vodURL: nil), .missingVODURL(streamID: "missing"))
        ] {
            XCTAssertThrowsError(try summary.runtimeValue.resolvedItem()) { XCTAssertEqual($0 as? HotMicPlayerConnectError, expected) }
        }
    }

    func testResolverCacheEvictionAndTypedErrorPaths() async throws {
        let client = FakeClient(summaries: [vod("one"), vod("two"),
            HotMicFixtureStreamSummary(id: "live", isVOD: false, vodURL: url),
            HotMicFixtureStreamSummary(id: "missing", isVOD: true, vodURL: nil)])
        let resolver = HotMicItemResolver(client: client, cacheCapacity: 1)
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
            ("other", "one", HotMicPlayerConnectError.unsupportedNamespace("other")),
            ("hotmic", "live", .notVOD(streamID: "live")),
            ("hotmic", "missing", .missingVODURL(streamID: "missing"))
        ] {
            do { _ = try await resolver.resolve(.init(namespace: namespace, id: id)); XCTFail("Expected typed error") }
            catch { XCTAssertEqual(error as? HotMicPlayerConnectError, expected) }
        }
        calls = await client.streamCalls
        XCTAssertEqual(calls, 5, "Unsupported namespaces must not fetch")
        let failing = HotMicItemResolver(client: FakeClient(fails: true))
        do { _ = try await failing.resolve(.init(namespace: "hotmic", id: "one")); XCTFail("Expected transport error") }
        catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
    }

    func testPagingFiltersWithoutLookupAndStopsAtHasNextFalse() async throws {
        let client = FakeClient(pages: [
            1: HotMicFixtureStreamPage(streams: [HotMicFixtureStreamSummary(id: "live", isVOD: false, vodURL: url),
                                      HotMicFixtureStreamSummary(id: "missing", isVOD: true, vodURL: nil)], currentPage: 1, hasNext: true),
            2: HotMicFixtureStreamPage(streams: [vod("one"), vod("one")], currentPage: 2, hasNext: false)
        ])
        let source = HotMicPlaylistSource(client: client)
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
        let client = FakeClient(pages: [4: HotMicFixtureStreamPage(streams: [], currentPage: 4, hasNext: false)])
        let query = HotMicStreamQuery(includesLive: true, includesScheduled: false, includesVOD: true,
                                      userID: "creator", page: 4, limit: 7)
        let source = HotMicPlaylistSource(client: client, query: query)
        _ = try await source.loadPage(cursor: nil)
        let received = await client.queries[0]
        XCTAssertEqual(received.page, 4); XCTAssertEqual(received.limit, 7); XCTAssertEqual(received.userID, "creator")
        XCTAssertTrue(received.includesLive); XCTAssertFalse(received.includesScheduled)
        for cursor in ["garbage", "0", "-1"] {
            do { _ = try await source.loadPage(cursor: cursor); XCTFail("Expected invalid cursor") }
            catch { XCTAssertEqual(error as? HotMicPlayerConnectError, .invalidCursor(cursor)) }
        }
        let pages = await client.requestedPages
        XCTAssertEqual(pages, [4])
    }

}
