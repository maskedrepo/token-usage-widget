import Foundation
import SQLite3

/// Reads Codex's usage. Exact per-response records come from the session logs in
/// ~/.codex/sessions (each counted once by response id, only new bytes read from a grown log); threads
/// whose logs Codex has compressed into archived_sessions count from its threads database instead.
final class CodexReader {
    private struct FileState {
        var size: Int
        var modified: Date
        var offset = 0
        var records: [String: Reply] = [:]  // response id → usage
        var messages: [Double] = []
        var limits: (seen: Double, windows: [[String: Any]])?
        var model = "?"
    }

    /// What the app needs beyond the page: today's tokens and when Codex was last used.
    struct Usage {
        var page: [String: Any]
        var today: Int
        var lastUsed: Double
    }

    private var files: [String: FileState] = [:]
    let base: URL

    /// Codex's folder is CODEX_HOME or ~/.codex unless given.
    init(base: URL? = nil) {
        let env = ProcessInfo.processInfo.environment["CODEX_HOME"]
        self.base = base ?? env.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    func usage(now: Date = Date()) -> Usage? {
        guard FileManager.default.fileExists(atPath: base.path) else { return nil }
        scan()
        var days: [String: Day] = [:], models: [String: [Int]] = [:], hours: [String: [Int]] = [:]
        var records: [String: Reply] = [:], exact = Set<String>()
        var limits: (seen: Double, windows: [[String: Any]])?
        var messages = 0, last = 0.0
        let calendar = Calendar.current
        for (path, state) in files {
            records.merge(state.records) { _, new in new }
            if !state.records.isEmpty { exact.insert(path) }
            for t in state.messages {
                let date = Date(timeIntervalSince1970: t), key = TranscriptReader.dayKey.string(from: date)
                days[key, default: Day()].m += 1
                var h = hours[key] ?? Array(repeating: 0, count: 24)
                h[calendar.component(.hour, from: date)] += 1
                hours[key] = h
                messages += 1
                last = max(last, t)
            }
            if let l = state.limits, l.seen > (limits?.seen ?? -1) { limits = l }
        }
        let todayKey = TranscriptReader.dayKey.string(from: now)
        var today = 0
        for r in records.values {
            let key = TranscriptReader.dayKey.string(from: r.time)
            days[key, default: Day()].add(r.model, r.counts)
            models[r.model] = zip(models[r.model] ?? [0, 0, 0, 0], r.counts).map(+)
            if key == todayKey { today += r.total }
            last = max(last, r.time.timeIntervalSince1970)
        }

        // Threads whose logs aren't readable count from the database's total, on the day of their last
        // activity; their split is estimated from each model's exact mix.
        let threads = Self.threads(in: base)
        var unsplit: [String: Int] = [:], sessions = 0, longest = 0.0
        for th in threads {
            sessions += 1
            days[TranscriptReader.dayKey.string(from: Date(timeIntervalSince1970: th.start)), default: Day()].sc += 1
            longest = max(longest, th.end - th.start)
            last = max(last, th.end)
            guard !exact.contains(th.path), th.tokens > 0 else { continue }
            let key = TranscriptReader.dayKey.string(from: Date(timeIntervalSince1970: th.end))
            days[key, default: Day()].tm[th.model, default: 0] += th.tokens
            unsplit[th.model, default: 0] += th.tokens
            if key == todayKey { today += th.tokens }
        }
        if records.isEmpty && threads.isEmpty { return nil }
        let overall = (0..<4).map { i in models.values.reduce(0) { $0 + $1[i] } }
        for (model, tokens) in unsplit {
            let own = models[model] ?? [0, 0, 0, 0]
            let mix = own.reduce(0, +) > 0 ? own : overall
            let whole = Double(mix.reduce(0, +))
            let share = whole > 0 ? mix.map { Double($0) / whole } : [1, 0, 0, 0]
            models[model] = zip(own, share).map { $0 + Int((Double(tokens) * $1).rounded()) }
        }

        var page: [String: Any] = [
            "days": days.mapValues { ["m": $0.m, "tm": $0.tm, "sp": $0.sp, "sc": $0.sc] as [String: Any] },
            "hours": hours,
            "models": models,
            "totals": ["sessions": sessions, "messages": messages, "longest": longest] as [String: Any],
            "sessions": threads.map { [$0.start, $0.end] },
            "modelsEstimated": !unsplit.isEmpty,
            "limits": limits?.windows ?? [],
            "lastUsed": last,
        ]
        if let seen = limits?.seen { page["limitsAt"] = seen }
        return Usage(page: page, today: today, lastUsed: last)
    }

    /// A day in the page's shape.
    struct Day {
        var m = 0, sc = 0
        var tm: [String: Int] = [:]
        var sp: [String: [Int]] = [:]

        mutating func add(_ model: String, _ counts: [Int]) {
            tm[model, default: 0] += counts.reduce(0, +)
            sp[model] = zip(sp[model] ?? [0, 0, 0, 0], counts).map(+)
        }
    }

    private func scan() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        var urls: [URL] = []
        if let walker = FileManager.default.enumerator(at: base.appendingPathComponent("sessions"), includingPropertiesForKeys: keys) {
            for case let url as URL in walker where url.pathExtension == "jsonl" { urls.append(url) }
        }
        let archived = base.appendingPathComponent("archived_sessions")
        urls += ((try? FileManager.default.contentsOfDirectory(at: archived, includingPropertiesForKeys: keys)) ?? [])
            .filter { $0.pathExtension == "jsonl" }
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let size = values.fileSize ?? 0, modified = values.contentModificationDate ?? .distantPast
            var state = files[url.path] ?? FileState(size: 0, modified: modified)
            if state.size == size && state.modified == modified && state.offset > 0 { continue }
            if size < state.offset || (size == state.size && state.modified != modified) {
                state = FileState(size: 0, modified: modified)
            }
            read(url, into: &state)
            state.size = size
            state.modified = modified
            files[url.path] = state
        }
    }

    private static let needles = ["\"token_usage_record\"", "\"turn_context\"", "\"user_message\"", "\"agent_message\"",
                                  "\"UserMessage\"", "\"AgentMessage\"", "\"rate_limits\""].map { Array($0.utf8) }

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
                if Self.needles.contains(where: { memmem(line, length, $0, $0.count) != nil }) {
                    parse(Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: line), count: length, deallocator: .none),
                          into: &state, path: url.path)
                }
                consumed = end + 1
            }
        }
        state.offset += consumed
    }

    private func parse(_ line: Data, into state: inout FileState, path: String) {
        guard let row = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let stamp = row["timestamp"] as? String, let time = TranscriptReader.date(stamp) else { return }
        let payload = row["payload"] as? [String: Any] ?? [:]
        let kind = row["type"] as? String, sub = payload["type"] as? String
        let t = time.timeIntervalSince1970
        switch kind {
        case "turn_context":
            state.model = payload["model"] as? String ?? state.model
        case "token_usage_record":
            guard let u = payload["usage"] as? [String: Any] else { return }
            let key = payload["response_id"] as? String ?? "\(path):\(row["ordinal"] ?? "")"
            state.records[key] = Reply(time: time, model: state.model, counts: Self.counts(u))
        case "event_msg":
            let item = (payload["item"] as? [String: Any])?["type"] as? String
            // Older Codex logs a user_message / agent_message event; newer logs a completed item.
            if sub == "user_message" || sub == "agent_message" || (sub == "item_completed" && (item == "UserMessage" || item == "AgentMessage")) {
                state.messages.append(t)
            } else if sub == "token_count", let raw = payload["rate_limits"] as? [String: Any] {
                state.limits = (t, Self.windows(raw))
            }
        default:
            break
        }
    }

    /// Codex usage as input / output / cache write / cache read; its input includes the cached part.
    private static func counts(_ u: [String: Any]) -> [Int] {
        let n = { (key: String) in (u[key] as? NSNumber)?.intValue ?? 0 }
        let cached = n("cached_input_tokens"), written = n("cache_write_input_tokens")
        return [max(0, n("input_tokens") - cached - written), n("output_tokens"), written, cached]
    }

    /// The plan's limit windows from a token_count event: minutes long, percent used, reset time.
    private static func windows(_ raw: [String: Any]) -> [[String: Any]] {
        ["primary", "secondary"].compactMap { key in
            guard let w = raw[key] as? [String: Any], let percent = w["used_percent"] as? NSNumber else { return nil }
            var out: [String: Any] = ["percent": percent]
            out["minutes"] = w["window_minutes"] as? NSNumber ?? NSNull()
            out["resetsAt"] = w["resets_at"] as? NSNumber ?? NSNull()
            return out
        }
    }

    private struct Thread {
        var path: String
        var start: Double
        var end: Double
        var tokens: Int
        var model: String
    }

    /// Every thread Codex knows, archived ones included, from its newest state database.
    private static func threads(in base: URL) -> [Thread] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        let number = { (name: String) in Int(name.filter(\.isNumber)) ?? 0 }
        guard let newest = names.filter({ $0.hasPrefix("state_") && $0.hasSuffix(".sqlite") }).max(by: { number($0) < number($1) })
        else { return [] }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(base.appendingPathComponent(newest).path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "select rollout_path, created_at, updated_at, tokens_used, model from threads"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        let text = { (column: Int32) in sqlite3_column_text(statement, column).map { String(cString: $0) } }
        var out: [Thread] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let start = Double(sqlite3_column_int64(statement, 1)), updated = Double(sqlite3_column_int64(statement, 2))
            out.append(Thread(path: text(0) ?? "", start: start, end: updated > 0 ? updated : start,
                              tokens: Int(sqlite3_column_int64(statement, 3)), model: text(4).flatMap { $0.isEmpty ? nil : $0 } ?? "?"))
        }
        return out
    }
}
