import Foundation

/// One API response: input, output, cache write, cache read.
struct Reply {
    var time: Date
    var model: String
    var counts: [Int]
    var total: Int { counts.reduce(0, +) }
}

/// A session's first and last main-thread message, as seconds since 1970.
struct Span {
    var lo: Double
    var hi: Double
}

/// The last limit Claude Code recorded, e.g. {status: "rejected", resetsAt: 1790560200}.
struct Quota {
    var seen: Date
    var status: String
    var resetsAt: Date
}

struct Window {
    var start: Date
    var end: Date
    var tokens: Int
}

struct Snapshot {
    var today = [0, 0, 0, 0]
    var todayByModel: [(model: String, tokens: Int)] = []
    var week: [(day: Date, tokens: Int)] = []  // last 7 days, oldest first
    var window: Window?
    var limit: Quota?  // only while a limit is still in force
    var allTime = 0
    var responses = 0
    var updated = Date()
    /// The dashboard's data, as JSON.
    var page = "null"
    var todayTotal: Int { today.reduce(0, +) }
    /// The tool used most recently, which the notch follows; Codex only counts when installed.
    var active = Tool.claude
    var codexToday = 0
    /// Codex's limit windows as it last logged them: minutes, percent, resetsAt.
    var codexLimits: [[String: Any]] = []
    /// Today's tokens in the tool the notch is showing.
    var activeToday: Int { active == .codex ? codexToday : todayTotal }

    /// How much of a limit the tool in use has spent, 0–100, or nil when it isn't known.
    /// Claude's comes from the plan; Codex's from its own log. A window that has reset since is back to 0.
    func percentUsed(_ shows: NotchShows, plan: PlanUsage?) -> Double? {
        let now = Date().timeIntervalSince1970
        if active == .codex {
            let minutes = shows == .weekly ? 10080 : 300
            guard let w = codexLimits.first(where: { ($0["minutes"] as? NSNumber)?.intValue == minutes }),
                  let percent = (w["percent"] as? NSNumber)?.doubleValue else { return nil }
            if let reset = (w["resetsAt"] as? NSNumber)?.doubleValue, reset < now { return 0 }
            return percent
        }
        guard let limit = shows == .weekly ? plan?.week : plan?.fiveHour else { return nil }
        if let reset = limit.resetsAt, reset.timeIntervalSince1970 < now { return 0 }
        return limit.percent
    }
}

/// What the closed notch shows beside the mark.
enum NotchShows: String, CaseIterable {
    case tokens, fiveHour, weekly

    var title: String {
        switch self {
        case .tokens: "Today's tokens"
        case .fiveHour: "5-hour limit"
        case .weekly: "Weekly limit"
        }
    }
}

enum Tool: String {
    case claude, codex
}

/// Reads Claude Code's transcripts, ~/.claude/projects/**/*.jsonl, counting each API response once
/// (message id + request id, largest of each count) and each message once (by uuid), and reads only
/// the new bytes of a grown file. History from stats-cache.json is merged in the same way.
final class TranscriptReader {
    private struct FileState {
        var size: Int
        var modified: Date
        var offset = 0
        var replies: [String: Reply] = [:]
        var rows: [String: Double] = [:]  // message uuid → time
        var spans: [String: Span] = [:]   // session → first / last main-thread message
        var quota: Quota?
    }

    private var files: [String: FileState] = [:]
    private let codex: CodexReader
    let base: URL
    var root: URL { base.appendingPathComponent("projects") }

    /// Claude Code's folder is CLAUDE_CONFIG_DIR or ~/.claude unless given; Codex's is CodexReader's.
    init(base: URL? = nil, codexBase: URL? = nil) {
        let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        self.base = base ?? env.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        codex = CodexReader(base: codexBase)
    }

    func snapshot(now: Date = Date()) -> Snapshot {
        scan()
        var replies: [String: Reply] = [:], rows: [String: Double] = [:], spans: [String: Span] = [:]
        var quota: Quota?
        // Files Claude Code has deleted stay counted.
        for state in files.values {
            for (key, reply) in state.replies {
                if var held = replies[key] {
                    held.counts = zip(held.counts, reply.counts).map { max($0, $1) }
                    replies[key] = held
                } else {
                    replies[key] = reply
                }
            }
            rows.merge(state.rows) { _, new in new }
            for (session, s) in state.spans {
                let held = spans[session] ?? s
                spans[session] = Span(lo: min(held.lo, s.lo), hi: max(held.hi, s.hi))
            }
            if let q = state.quota, q.seen > (quota?.seen ?? .distantPast) { quota = q }
        }
        var snap = Self.summarize(Array(replies.values), quota: quota, now: now)
        var page = pageData(replies: Array(replies.values), rows: Array(rows.values), spans: Array(spans.values), now: now)
        let claudeLast = replies.values.map { $0.time.timeIntervalSince1970 }.max() ?? 0
        page["lastUsed"] = claudeLast
        // Codex, when installed, rides along; the notch and page follow whichever was used last.
        if let codex = codex.usage(now: now) {
            page["codex"] = codex.page
            snap.active = codex.lastUsed > claudeLast ? .codex : .claude
            snap.codexToday = codex.today
            snap.codexLimits = codex.page["limits"] as? [[String: Any]] ?? []
            page["active"] = snap.active.rawValue
        }
        if let json = try? JSONSerialization.data(withJSONObject: page) { snap.page = String(decoding: json, as: UTF8.self) }
        return snap
    }

    private func scan() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return }
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let size = values.fileSize ?? 0, modified = values.contentModificationDate ?? .distantPast
            var state = files[url.path] ?? FileState(size: 0, modified: modified)
            if state.size == size && state.modified == modified && state.offset > 0 { continue }
            // Transcripts only grow; anything else means it was rewritten, so start over.
            if size < state.offset || (size == state.size && state.modified != modified) {
                state = FileState(size: 0, modified: modified)
            }
            read(url, into: &state)
            state.size = size
            state.modified = modified
            files[url.path] = state
        }
    }

    private static let needle = Array("\"timestamp\"".utf8)

    private func read(_ url: URL, into state: inout FileState) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(state.offset))) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return }
        var consumed = 0
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            let count = buffer.count
            // Only whole lines; an unfinished last line is read again next time.
            while consumed < count, let newline = memchr(base + consumed, 0x0A, count - consumed) {
                let end = base.distance(to: UnsafeRawPointer(newline))
                let length = end - consumed
                let line = base + consumed
                if memmem(line, length, Self.needle, Self.needle.count) != nil {
                    parse(Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: line), count: length, deallocator: .none),
                          into: &state)
                }
                consumed = end + 1
            }
        }
        state.offset += consumed
    }

    private func parse(_ line: Data, into state: inout FileState) {
        guard let row = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let stamp = row["timestamp"] as? String, let time = Self.date(stamp) else { return }
        if let q = row["quotaLimits"] as? [String: Any], let resets = (q["resetsAt"] as? NSNumber)?.doubleValue,
           time > (state.quota?.seen ?? .distantPast) {
            state.quota = Quota(seen: time, status: q["status"] as? String ?? "", resetsAt: Date(timeIntervalSince1970: resets))
        }
        let kind = row["type"] as? String
        guard let session = row["sessionId"] as? String, !session.isEmpty, kind == "user" || kind == "assistant" else { return }
        let t = time.timeIntervalSince1970
        if row["isSidechain"] as? Bool != true {
            let held = state.spans[session] ?? Span(lo: t, hi: t)
            state.spans[session] = Span(lo: min(held.lo, t), hi: max(held.hi, t))
        }
        if let uuid = row["uuid"] as? String, !uuid.isEmpty, row["isMeta"] as? Bool != true {
            state.rows[uuid] = t
        }
        guard kind == "assistant", let message = row["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any], !usage.isEmpty else { return }
        let model = (message["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "?"
        if model == "<synthetic>" { return }
        let counts = ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
            .map { (usage[$0] as? NSNumber)?.intValue ?? 0 }
        let key = "\(message["id"] as? String ?? "None")|\(row["requestId"] as? String ?? "None")"
        if var held = state.replies[key] {
            held.counts = zip(held.counts, counts).map { max($0, $1) }
            state.replies[key] = held
        } else {
            state.replies[key] = Reply(time: time, model: model, counts: counts)
        }
    }

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let whole = ISO8601DateFormatter()

    static func date(_ s: String) -> Date? { fractional.date(from: s) ?? whole.date(from: s) }

    private static func localFormat(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        return f
    }
    static let dayKey = localFormat("yyyy-MM-dd")
    static let stampKey = localFormat("yyyy-MM-dd'T'HH:mm:ss")

    /// The dashboard's data: stats-cache.json history up to its last computed UTC day, transcripts
    /// after that, days keyed by local date.
    private func pageData(replies: [Reply], rows: [Double], spans: [Span], now: Date) -> [String: Any] {
        var stats: [String: Any]?
        if let raw = try? Data(contentsOf: base.appendingPathComponent("stats-cache.json")) {
            stats = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
        }
        var cutoff = 0.0
        if let last = stats?["lastComputedDate"] as? String {
            let utc = DateFormatter()
            utc.locale = Locale(identifier: "en_US_POSIX")
            utc.timeZone = TimeZone(identifier: "UTC")
            utc.dateFormat = "yyyy-MM-dd"
            if let day = utc.date(from: last) { cutoff = day.timeIntervalSince1970 + 86400 }
        }

        var days: [String: (m: Int, tm: [String: Int], sp: [String: [Int]], sc: Int)] = [:]
        func edit(_ key: String, _ change: (inout (m: Int, tm: [String: Int], sp: [String: [Int]], sc: Int)) -> Void) {
            var d = days[key] ?? (0, [:], [:], 0)
            change(&d)
            days[key] = d
        }
        var models: [String: [Int]] = [:]
        var sessions = 0, messages = 0, longest = 0.0

        if let stats {
            for a in stats["dailyActivity"] as? [[String: Any]] ?? [] {
                guard let key = a["date"] as? String else { continue }
                edit(key) {
                    $0.m += (a["messageCount"] as? NSNumber)?.intValue ?? 0
                    $0.sc += (a["sessionCount"] as? NSNumber)?.intValue ?? 0
                }
            }
            for a in stats["dailyModelTokens"] as? [[String: Any]] ?? [] {
                guard let key = a["date"] as? String else { continue }
                edit(key) { d in
                    for (model, n) in a["tokensByModel"] as? [String: Any] ?? [:] {
                        d.tm[model, default: 0] += (n as? NSNumber)?.intValue ?? 0
                    }
                }
            }
            for (model, u) in stats["modelUsage"] as? [String: [String: Any]] ?? [:] {
                models[model] = ["inputTokens", "outputTokens", "cacheCreationInputTokens", "cacheReadInputTokens"]
                    .map { (u[$0] as? NSNumber)?.intValue ?? 0 }
            }
            sessions = (stats["totalSessions"] as? NSNumber)?.intValue ?? 0
            messages = (stats["totalMessages"] as? NSNumber)?.intValue ?? 0
            longest = ((stats["longestSession"] as? [String: Any])?["duration"] as? NSNumber)?.doubleValue ?? 0
            longest /= 1000
        }

        for r in replies where r.time.timeIntervalSince1970 >= cutoff {
            edit(Self.dayKey.string(from: r.time)) { d in
                d.tm[r.model, default: 0] += r.total
                let held = d.sp[r.model] ?? [0, 0, 0, 0]
                d.sp[r.model] = zip(held, r.counts).map(+)
            }
            models[r.model] = zip(models[r.model] ?? [0, 0, 0, 0], r.counts).map(+)
        }
        var hours: [String: [Int]] = [:]
        let calendar = Calendar.current
        for t in rows {
            let date = Date(timeIntervalSince1970: t)
            let key = Self.dayKey.string(from: date)
            if t >= cutoff {
                edit(key) { $0.m += 1 }
                messages += 1
            }
            // Hours of day from every message seen (history included), for peak hour.
            var h = hours[key] ?? Array(repeating: 0, count: 24)
            h[calendar.component(.hour, from: date)] += 1
            hours[key] = h
        }
        for s in spans {
            if s.lo >= cutoff {
                edit(Self.dayKey.string(from: Date(timeIntervalSince1970: s.lo))) { $0.sc += 1 }
                sessions += 1
            }
            longest = max(longest, s.hi - s.lo)
        }

        let data: [String: Any] = [
            "generatedAt": Self.stampKey.string(from: now),
            "today": Self.dayKey.string(from: now),
            "days": days.mapValues { ["m": $0.m, "tm": $0.tm, "sp": $0.sp, "sc": $0.sc] as [String: Any] },
            "hours": hours,
            "models": models,
            "totals": ["sessions": sessions, "messages": messages, "longest": longest] as [String: Any],
            "sessions": spans.map { [$0.lo, $0.hi] },
        ]
        return data
    }

    static let windowLength: TimeInterval = 5 * 3600

    static func summarize(_ replies: [Reply], quota: Quota?, now: Date) -> Snapshot {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        var snap = Snapshot(updated: now)
        var byModel: [String: Int] = [:]
        var byDay: [Date: Int] = [:]
        let weekStart = calendar.date(byAdding: .day, value: -6, to: todayStart)!
        for r in replies {
            snap.allTime += r.total
            if r.time >= todayStart {
                for i in 0..<4 { snap.today[i] += r.counts[i] }
                byModel[r.model, default: 0] += r.total
            }
            if r.time >= weekStart { byDay[calendar.startOfDay(for: r.time), default: 0] += r.total }
        }
        snap.responses = replies.count
        snap.todayByModel = byModel.map { ($0.key, $0.value) }.sorted { $0.tokens > $1.tokens }
        snap.week = (0..<7).map { back in
            let day = calendar.date(byAdding: .day, value: back - 6, to: todayStart)!
            return (day, byDay[day] ?? 0)
        }

        // Five-hour windows the way usage tools estimate them: a window opens on the hour of the
        // first response after the last one closed, and lasts five hours.
        var start: Date?, tokens = 0
        for r in replies.sorted(by: { $0.time < $1.time }) {
            if let s = start, r.time < s.addingTimeInterval(windowLength) {
                tokens += r.total
            } else {
                start = calendar.dateInterval(of: .hour, for: r.time)?.start ?? r.time
                tokens = r.total
            }
        }
        if let s = start, now < s.addingTimeInterval(windowLength) {
            snap.window = Window(start: s, end: s.addingTimeInterval(windowLength), tokens: tokens)
        }
        if let q = quota, q.status != "allowed", q.resetsAt > now { snap.limit = q }
        return snap
    }
}
