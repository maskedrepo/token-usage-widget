import Foundation
import JavaScriptCore
import Testing
@testable import TokenNotch

/// The dashboard's own script, run in JavaScriptCore with just enough of a page around it to draw.
final class Dashboard {
    let context = JSContext()!
    private(set) var errors: [String] = []

    static let source: String = {
        let page = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("dashboard.html")
        let html = (try? String(contentsOf: page, encoding: .utf8)) ?? ""
        let script = html.range(of: "<script>").flatMap { open in
            html.range(of: "</script>", range: open.upperBound..<html.endIndex).map { String(html[open.upperBound..<$0.lowerBound]) }
        }
        return script ?? ""
    }()

    // Every element is the same do-nothing stand-in; the views write strings into innerHTML.
    private static let stage = """
        const stub = () => new Proxy(function () {}, {
          get: (target, key) => key === Symbol.toPrimitive ? () => 0 : key === "clientWidth" ? 572 : key in target ? target[key] : stub(),
          set: (target, key, value) => { target[key] = value; return true; },
          apply: () => stub(),
        });
        globalThis.window = globalThis;
        globalThis.document = stub();
        globalThis.addEventListener = () => {};
        globalThis.innerWidth = 600;
        """

    init(data: [String: Any]) throws {
        context.exceptionHandler = { [unowned self] _, error in errors.append(error?.toString() ?? "?") }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: data), as: UTF8.self)
        #expect(Self.source.contains("/*PAGE_DATA*/null"))
        context.evaluateScript(Self.stage)
        // `let`s and functions at the top of the script stay reachable from later evaluations.
        context.evaluateScript(Self.source.replacingOccurrences(of: "/*PAGE_DATA*/null", with: json))
    }

    func run(_ expression: String) -> Any? {
        context.evaluateScript("JSON.stringify(\(expression))").flatMap { $0.isUndefined ? nil : $0.toString() }
            .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8), options: .fragmentsAllowed) }
    }
}

private func data(days: [String: Any], models: [String: [Int]]) -> [String: Any] {
    ["generatedAt": "2026-01-10T12:00:00", "today": "2026-01-10", "days": days, "hours": [String: Any](),
     "models": models, "totals": ["sessions": 1, "messages": 1, "longest": 0], "sessions": [Any]()]
}

@Suite struct DashboardScript {
    @Test func drawsEveryViewOfTheDemoData() throws {
        let page = try Dashboard(data: DemoData.page())
        for state in ["{tab: 'overview', more: true}", "{tab: 'models', range: '7'}", "{tool: 'codex', range: '1'}",
                      "{tool: 'codex', tab: 'models', range: 'all'}"] {
            _ = page.run("notch.show(\(state))")
        }
        _ = page.run("notch.limits({label: '5-hour', value: '42%', fraction: .42, side: {label: 'Weekly', value: '61%'}})")
        _ = page.run("notch.settings({animate: false, shows: 'weekly'})")
        #expect(page.errors.isEmpty, "\(page.errors)")
    }

    @Test func namesModelsLikeTheApp() throws {
        let page = try Dashboard(data: data(days: [:], models: [:]))
        let ids = ["claude-sonnet-4-5-20250929", "claude-opus-5-5", "claude-opus-4-6[1m]", "claude-3-5-sonnet-20241022",
                   "gpt-5.6-sol", "gpt-reserve", "codex-auto-review", "<custom>"]
        let names = page.run("\(String(decoding: try JSONSerialization.data(withJSONObject: ids), as: UTF8.self)).map(modelLabel)") as? [String]
        #expect(names == ["Sonnet 4.5", "Opus 5.5", "Opus 4.6", "claude-3-5-sonnet-20241022", "GPT-5.6 Sol", "gpt-reserve", "Codex Auto Review",
                          "<custom>"])
        for id in ids where id.hasPrefix("claude") { #expect(names?[ids.firstIndex(of: id)!] == Format.model(id)) }
    }

    @Test func usesTheExactSplitWhereTheTranscriptsKeptOne() throws {
        // The all-time mix is all input, so estimating would have put these days' tokens there.
        let page = try Dashboard(data: data(days: [
            "2026-01-09": ["m": 1, "tm": ["claude-opus-5-5": 10], "sp": ["claude-opus-5-5": [0, 10, 0, 0]], "sc": 1],
            "2026-01-10": ["m": 1, "tm": ["claude-haiku-5-5": 7], "sp": ["claude-haiku-5-5": [1, 2, 3, 1]], "sc": 0],
        ], models: ["claude-opus-5-5": [100, 0, 0, 0], "claude-haiku-5-5": [40, 0, 0, 0]]))
        #expect(page.run("summarize(TOOLS.claude.data, '7').tokens") as? [Int] == [1, 12, 3, 1])
        #expect(page.run("summarize(TOOLS.claude.data, '7').estimated") as? Bool == false)
    }

    @Test func estimatesOnlyWhatHistoryKeptAsATotal() throws {
        // 30 tokens from history without a split, plus 10 from transcripts with one, on the same day.
        let page = try Dashboard(data: data(days: [
            "2026-01-10": ["m": 2, "tm": ["claude-opus-5-5": 40], "sp": ["claude-opus-5-5": [0, 10, 0, 0]], "sc": 1],
        ], models: ["claude-opus-5-5": [0, 0, 0, 100]]))
        #expect(page.run("summarize(TOOLS.claude.data, '1').tokens") as? [Int] == [0, 10, 0, 30])
        #expect(page.run("summarize(TOOLS.claude.data, '1').estimated") as? Bool == true)
    }

    @Test func countsStreaksBackFromYesterdayWhileTodayIsQuiet() throws {
        let day = { (m: Int) in ["m": m, "tm": ["claude-opus-5-5": m * 10], "sp": [String: Any](), "sc": 1] as [String: Any] }
        let page = try Dashboard(data: data(days: ["2026-01-06": day(1), "2026-01-08": day(1), "2026-01-09": day(3)],
                                            models: ["claude-opus-5-5": [0, 0, 0, 50]]))
        let s = page.run("(s => [s.streak, s.longestStreak, s.active.length, s.span, s.busiest])(summarize(TOOLS.claude.data, '7'))") as? [Any]
        #expect(s?[0] as? Int == 2)
        #expect(s?[1] as? Int == 2)
        #expect(s?[2] as? Int == 3)
        #expect(s?[3] as? Int == 7)
        #expect(s?[4] as? String == "2026-01-09")
    }

    @Test func aCodexWindowThatHasResetShowsZero() throws {
        let page = try Dashboard(data: data(days: [:], models: [:]))
        let row = page.run("codexLimit([{minutes: 300, percent: 80, resetsAt: 100}, {minutes: 10080, percent: 96, resetsAt: 9e9}], 200)")
            as? [String: Any]
        #expect(row?["label"] as? String == "5-hour")
        #expect(row?["value"] as? String == "0%")
        #expect((row?["side"] as? [String: Any])?["value"] as? String == "96%")
        #expect((row?["side"] as? [String: Any])?["level"] as? String == "over")
    }
}
