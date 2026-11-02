import Foundation
import Testing
@testable import TokenNotch

/// A throwaway folder standing in for ~/.claude or ~/.codex.
final class Folder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("token-notch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    /// Writes one JSON object per line.
    func lines(_ path: String, _ rows: [[String: Any]]) throws {
        let text = try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\n" }.joined()
        try write(path, text)
    }

    func write(_ path: String, _ text: String) throws {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }
}

private let stamp: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

/// Noon today, so an hour either side is still today.
private let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
private let todayKey = TranscriptReader.dayKey.string(from: noon)

private func claudeRow(_ kind: String, uuid: String, at time: Date, session: String = "s1",
                       extra: [String: Any] = [:]) -> [String: Any] {
    ["type": kind, "uuid": uuid, "sessionId": session, "timestamp": stamp.string(from: time)].merging(extra) { $1 }
}

private func reply(id: String, request: String, model: String = "claude-opus-5-5", _ counts: [Int]) -> [String: Any] {
    let names = ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
    return ["requestId": request, "message": ["id": id, "model": model,
                                               "usage": Dictionary(uniqueKeysWithValues: zip(names, counts))]]
}

private func page(_ json: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}

private func ints(_ value: Any?) -> [Int]? { (value as? [NSNumber])?.map(\.intValue) }

@Suite struct ClaudeReading {
    @Test func aStreamedReplyCountsOnceWithItsLargestCounts() throws {
        let claude = try Folder(), codex = try Folder()
        let hourAgo = noon.addingTimeInterval(-3600)
        try claude.lines("projects/app/one.jsonl", [
            claudeRow("user", uuid: "u1", at: hourAgo),
            // The same response logged twice while it streamed: only the larger output counts.
            claudeRow("assistant", uuid: "u2", at: hourAgo.addingTimeInterval(5), extra: reply(id: "m1", request: "r1", [10, 5, 100, 1000])),
            claudeRow("assistant", uuid: "u3", at: hourAgo.addingTimeInterval(9), extra: reply(id: "m1", request: "r1", [10, 50, 100, 1000])),
            // Claude Code's own placeholder replies aren't API usage.
            claudeRow("assistant", uuid: "u4", at: hourAgo.addingTimeInterval(20),
                      extra: reply(id: "m2", request: "r2", model: "<synthetic>", [999, 999, 0, 0])),
            // A subagent's reply counts, but doesn't stretch the session.
            claudeRow("assistant", uuid: "u5", at: noon.addingTimeInterval(1800),
                      extra: reply(id: "m3", request: "r3", model: "claude-haiku-5-5", [1, 2, 0, 0]).merging(["isSidechain": true]) { $1 }),
        ])
        let snap = TranscriptReader(base: claude.url, codexBase: codex.url.appendingPathComponent("missing")).snapshot(now: noon)

        #expect(snap.responses == 2)
        #expect(snap.today == [11, 52, 100, 1000])
        #expect(snap.todayByModel.first?.model == "claude-opus-5-5")
        let data = try page(snap.page)
        let day = try #require((data["days"] as? [String: [String: Any]])?[todayKey])
        #expect(ints((day["sp"] as? [String: Any])?["claude-opus-5-5"]) == [10, 50, 100, 1000])
        #expect((day["tm"] as? [String: NSNumber])?["claude-haiku-5-5"] == 3)
        #expect((day["m"] as? NSNumber) == 5)
        let sessions = try #require(data["sessions"] as? [[Double]])
        #expect(sessions.count == 1 && sessions[0][1] - sessions[0][0] == 20)
        #expect(data["codex"] == nil)
    }

    @Test func historyFromTheStatsCacheStopsWhereTranscriptsTakeOver() throws {
        let claude = try Folder()
        let utc = DateFormatter()
        utc.locale = Locale(identifier: "en_US_POSIX")
        utc.timeZone = TimeZone(identifier: "UTC")
        utc.dateFormat = "yyyy-MM-dd"
        let computed = noon.addingTimeInterval(-10 * 86400)
        let historyDay = TranscriptReader.dayKey.string(from: noon.addingTimeInterval(-13 * 86400))
        try claude.write("stats-cache.json", """
            {"lastComputedDate": "\(utc.string(from: computed))",
             "dailyActivity": [{"date": "\(historyDay)", "messageCount": 7, "sessionCount": 2}],
             "dailyModelTokens": [{"date": "\(historyDay)", "tokensByModel": {"claude-sonnet-5-5": 500}}],
             "modelUsage": {"claude-sonnet-5-5": {"inputTokens": 50, "outputTokens": 50, "cacheCreationInputTokens": 100,
                                                  "cacheReadInputTokens": 300}},
             "totalSessions": 2, "totalMessages": 7, "longestSession": {"duration": 60000}}
            """)
        // One reply the cache already has (on its last day), one after it.
        let old = utc.date(from: utc.string(from: computed))!.addingTimeInterval(12 * 3600)
        try claude.lines("projects/app/one.jsonl", [
            claudeRow("assistant", uuid: "a1", at: old, session: "old", extra: reply(id: "m1", request: "r1", [1, 1, 1, 1])),
            claudeRow("user", uuid: "a2", at: noon),
            claudeRow("assistant", uuid: "a3", at: noon.addingTimeInterval(10), extra: reply(id: "m2", request: "r2", [2, 2, 2, 2])),
        ])
        let snap = TranscriptReader(base: claude.url, codexBase: claude.url.appendingPathComponent("none")).snapshot(now: noon)
        let data = try page(snap.page)
        let days = try #require(data["days"] as? [String: [String: Any]])

        #expect(snap.allTime == 12)
        #expect((days[historyDay]?["tm"] as? [String: NSNumber])?["claude-sonnet-5-5"] == 500)
        #expect((days[TranscriptReader.dayKey.string(from: old)]?["tm"] as? [String: NSNumber])?["claude-opus-5-5"] == nil)
        #expect(ints((data["models"] as? [String: Any])?["claude-opus-5-5"]) == [2, 2, 2, 2])
        let totals = try #require(data["totals"] as? [String: NSNumber])
        #expect(totals["messages"] == 9 && totals["sessions"] == 3)
    }
}

@Suite struct CodexReading {
    private func event(_ type: String, at time: Date, _ payload: [String: Any]) -> [String: Any] {
        ["type": "event_msg", "timestamp": stamp.string(from: time), "payload": ["type": type].merging(payload) { $1 }]
    }

    private func record(_ response: String, at time: Date, input: Int, cached: Int, output: Int) -> [String: Any] {
        ["type": "token_usage_record", "timestamp": stamp.string(from: time),
         "payload": ["response_id": response, "usage": ["input_tokens": input, "cached_input_tokens": cached,
                                                         "cache_write_input_tokens": 0, "output_tokens": output]]]
    }

    private func codexHome(resetsIn seconds: Double) throws -> Folder {
        let codex = try Folder()
        let reset = noon.timeIntervalSince1970 + seconds
        try codex.lines("sessions/2026/01/10/rollout.jsonl", [
            ["type": "turn_context", "timestamp": stamp.string(from: noon), "payload": ["model": "gpt-5.6-sol"]],
            event("user_message", at: noon, [:]),
            record("resp-1", at: noon.addingTimeInterval(4), input: 1000, cached: 800, output: 50),
            record("resp-1", at: noon.addingTimeInterval(4), input: 1000, cached: 800, output: 50),
            event("agent_message", at: noon.addingTimeInterval(5), [:]),
            event("token_count", at: noon.addingTimeInterval(6), ["rate_limits": [
                "primary": ["used_percent": 30, "window_minutes": 300, "resets_at": reset],
                "secondary": ["used_percent": 55, "window_minutes": 10080, "resets_at": reset + 86400],
            ]]),
        ])
        return codex
    }

    @Test func recordsCountOnceWithCachedInputTakenOutOfInput() throws {
        let codex = try codexHome(resetsIn: 3600)
        let usage = try #require(CodexReader(base: codex.url).usage(now: noon))
        #expect(usage.today == 1050)
        let day = try #require((usage.page["days"] as? [String: [String: Any]])?[todayKey])
        #expect(day["sp"] as? [String: [Int]] == ["gpt-5.6-sol": [200, 50, 0, 800]])
        #expect(day["m"] as? Int == 2)
        let limits = try #require(usage.page["limits"] as? [[String: Any]])
        #expect(limits.compactMap { ($0["minutes"] as? NSNumber)?.intValue } == [300, 10080])
    }

    @Test func theNotchFollowsCodexWhenItWasUsedLast() throws {
        let codex = try codexHome(resetsIn: 3600), claude = try Folder()
        let snap = TranscriptReader(base: claude.url, codexBase: codex.url).snapshot(now: noon)
        #expect(snap.active == .codex)
        #expect(snap.activeToday == 1050)
        #expect(snap.percentUsed(.weekly, plan: nil) == 55)
        #expect((try page(snap.page))["active"] as? String == "codex")
    }

    @Test func aLimitThatHasResetReadsZero() throws {
        let codex = try codexHome(resetsIn: -24 * 3600 - 60)
        let snap = TranscriptReader(base: try Folder().url, codexBase: codex.url).snapshot(now: noon)
        #expect(snap.percentUsed(.fiveHour, plan: nil) == 0)
    }
}

@Test(arguments: [
    ("claude-opus-5-5", "Opus 5.5"), ("claude-sonnet-4-5-20250929", "Sonnet 4.5"), ("claude-opus-4-20250514", "Opus 4"),
    ("claude-opus-4-6[1m]", "Opus 4.6"), ("claude-3-5-sonnet-20241022", "claude-3-5-sonnet-20241022"), ("<custom>", "<custom>"),
])
func modelNames(id: String, name: String) {
    #expect(Format.model(id) == name)
}

@Test func demoDataHasBothTools() throws {
    let data = DemoData.page(now: noon)
    #expect(data["today"] as? String == todayKey)
    #expect((data["days"] as? [String: Any])?.count ?? 0 > 50)
    let codex = try #require(data["codex"] as? [String: Any])
    #expect((codex["limits"] as? [[String: Any]])?.count == 2)
    #expect(JSONSerialization.isValidJSONObject(data))
}
