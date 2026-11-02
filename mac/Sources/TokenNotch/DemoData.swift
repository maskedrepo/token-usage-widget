import Foundation

/// Made-up page data for the README's pictures: about five months of Claude Code and Codex use,
/// the same every run for a given day.
enum DemoData {
    /// A small seeded generator (SplitMix64), so the pictures don't change from run to run.
    private struct Dice {
        var state: UInt64
        mutating func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
        mutating func between(_ low: Double, _ high: Double) -> Double { low + (high - low) * next() }
    }

    /// Input, output, cache write and cache read, as shares of a day's tokens.
    private static let mix = [0.0004, 0.005, 0.045, 0.9496]

    static func page(now: Date = Date()) -> [String: Any] {
        var claude = tool(models: [("claude-opus-5-5", 0.68), ("claude-sonnet-5-5", 0.27), ("claude-haiku-5-5", 0.05)],
                          seed: 21, busy: 0.85, now: now)
        var codex = tool(models: [("gpt-5.6-sol", 0.62), ("gpt-5.5", 0.28), ("gpt-5.4-mini", 0.1)],
                         seed: 34, busy: 0.6, now: now)
        let evening = Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: now) ?? now
        codex["limits"] = [
            ["minutes": 300, "percent": 23, "resetsAt": evening.timeIntervalSince1970],
            ["minutes": 10080, "percent": 47, "resetsAt": evening.timeIntervalSince1970 + 3 * 86400],
        ]
        codex["modelsEstimated"] = false
        codex["lastUsed"] = (claude["lastUsed"] as? Double ?? 0) - 3600
        claude["generatedAt"] = TranscriptReader.stampKey.string(from: now)
        claude["today"] = TranscriptReader.dayKey.string(from: now)
        claude["codex"] = codex
        claude["active"] = "claude"
        return claude
    }

    private static func tool(models: [(id: String, share: Double)], seed: UInt64, busy: Double, now: Date) -> [String: Any] {
        var dice = Dice(state: seed)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        var days: [String: Any] = [:], hours: [String: [Int]] = [:], sessions: [[Double]] = []
        var totals = Dictionary(uniqueKeysWithValues: models.map { ($0.id, [0, 0, 0, 0]) })
        var messages = 0, sessionCount = 0

        for back in 0..<150 {
            // Busier lately than five months ago.
            guard dice.next() < (back < 70 ? busy : busy * 0.4),
                  let day = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
            let sent = Int(dice.between(150, 1100))
            let started = Int(dice.between(1, 7))
            let tokens = Double(sent) * dice.between(70_000, 140_000)
            var byModel: [String: Int] = [:], split: [String: [Int]] = [:]
            for model in models {
                let counts = mix.map { Int(tokens * model.share * dice.between(0.6, 1.4) * $0) }
                split[model.id] = counts
                byModel[model.id] = counts.reduce(0, +)
                totals[model.id] = zip(totals[model.id]!, counts).map(+)
            }
            let key = TranscriptReader.dayKey.string(from: day)
            days[key] = ["m": sent, "tm": byModel, "sp": split, "sc": started] as [String: Any]
            // Mostly afternoons and evenings.
            var perHour = Array(repeating: 0, count: 24)
            for _ in 0..<sent { perHour[min(23, Int(dice.between(9, 15) + dice.between(0, 9)))] += 1 }
            hours[key] = perHour
            let afternoon = day.timeIntervalSince1970 + 14 * 3600
            for _ in 0..<started { sessions.append([afternoon, afternoon + dice.between(600, 30_000)]) }
            messages += sent
            sessionCount += started
        }
        return [
            "days": days, "hours": hours, "models": totals, "sessions": sessions,
            "totals": ["sessions": sessionCount, "messages": messages, "longest": 3 * 86400 + 5400] as [String: Any],
            "lastUsed": today.timeIntervalSince1970 + 21 * 3600,
        ]
    }
}
