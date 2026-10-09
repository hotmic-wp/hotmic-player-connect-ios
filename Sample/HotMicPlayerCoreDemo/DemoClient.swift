import Foundation
import HotMicCore

/// Public MDN MP4 and Apple VOD HLS fixtures. No HotMic API is contacted.
actor DemoClient: CoreStreamClient {

    private func summary(_ id: String) -> CoreStreamSummary {
        let url = id == "sample-6"
            ? "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/bipbop_4x3_variant.m3u8"
            : "https://interactive-examples.mdn.mozilla.net/media/cc0-videos/flower.mp4"
        return CoreStreamSummary(id: id, isVOD: id != "bad-live",
                                 vodURL: id == "bad-missing" ? nil : URL(string: url),
                                 title: "Demo \(id)", duration: id == "sample-6" ? 1800 : 5.05)
    }

    func fetchStream(id: String) async throws -> CoreStreamSummary {
        try Task.checkCancellation()
        await DemoEvidence.shared.record("fetchStream", ["id": id])
        return summary(id)
    }

    func fetchStreams(matching query: HotMicStreamQuery) async throws -> CoreStreamPage {
        try Task.checkCancellation()
        await DemoEvidence.shared.record("fetchPage", ["page": String(query.page)])
        let ids: [String]
        switch query.page {
        case 1: ids = ["sample-1", "bad-live", "sample-2", "bad-missing", "sample-3", "sample-4", "sample-5"]
        case 2: ids = ["sample-5", "sample-6", "sample-7"] // overlap: player owns de-duplication
        default: ids = []
        }
        return CoreStreamPage(streams: ids.map(summary), currentPage: query.page, hasNext: query.page == 1)
    }
}

/// Fake-mode evidence only. Never receives credentials, raw errors or Core responses.
actor DemoEvidence {
    static let shared = DemoEvidence()
    func record(_ event: String, _ fields: [String: String] = [:]) {
        var row = fields
        row["event"] = event
        row["time"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = documents.appendingPathComponent("demo-evidence.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data([10]))
    }
}

struct DemoCredentials: Decodable {
    let HOTMIC_API_KEY: String
    let HOTMIC_ACCESS_TOKEN: String

    static func load() -> Self? {
        let environment = ProcessInfo.processInfo.environment
        if let key = environment["HOTMIC_API_KEY"], let token = environment["HOTMIC_ACCESS_TOKEN"],
           !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Self(HOTMIC_API_KEY: key, HOTMIC_ACCESS_TOKEN: token)
        }
        // Runtime-only file in the app sandbox. It is never bundled into the app.
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = try? Data(contentsOf: documents.appendingPathComponent("HotMicCredentials.json")),
              let credentials = try? JSONDecoder().decode(Self.self, from: data),
              !credentials.HOTMIC_API_KEY.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !credentials.HOTMIC_ACCESS_TOKEN.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return credentials
    }
}
