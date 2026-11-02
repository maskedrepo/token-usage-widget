import Foundation

/// How much of the plan's limits are used, as Claude Code's /usage shows them. The transcripts
/// don't record this, so it comes from the account: the app borrows Claude Code's own sign-in from
/// the Keychain and asks Anthropic. The sign-in is read fresh each time and never stored or logged.
struct PlanUsage {
    struct Limit {
        var percent: Double  // 0–100
        var resetsAt: Date?
    }

    var fiveHour: Limit?
    var week: Limit?

    enum Failure: Error {
        case signedOut     // no Claude Code sign-in in the Keychain
        case expired       // the sign-in was turned down; using Claude Code renews it
        case unavailable   // network trouble, or the answer changed shape

        var message: String {
            switch self {
            case .signedOut: "No Claude Code sign-in found for plan limits"
            case .expired: "Open Claude Code to refresh plan limits"
            case .unavailable: "Plan limits unavailable"
            }
        }
    }

    // Not a published API: it is what Claude Code's /usage reads, so it may change without notice.
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func fetch() -> Result<PlanUsage, Failure> {
        guard let token = signInToken() else { return .failure(.signedOut) }
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var result: Result<PlanUsage, Failure> = .failure(.unavailable)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { done.signal() }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 { result = .failure(.expired); return }
            guard status == 200, let data, let usage = parse(data) else { return }
            result = .success(usage)
        }.resume()
        done.wait()
        return result
    }

    static func parse(_ data: Data) -> PlanUsage? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let usage = PlanUsage(fiveHour: limit(json["five_hour"]), week: limit(json["seven_day"]))
        return usage.fiveHour == nil && usage.week == nil ? nil : usage
    }

    private static func limit(_ value: Any?) -> Limit? {
        guard let entry = value as? [String: Any], let percent = (entry["utilization"] as? NSNumber)?.doubleValue else { return nil }
        return Limit(percent: percent, resetsAt: (entry["resets_at"] as? String).flatMap(date))
    }

    private static func date(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// Claude Code's access token. Read through `security`, which Claude Code itself uses for this
    /// Keychain item, so macOS doesn't ask again each time the app is rebuilt.
    private static func signInToken() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return token
    }
}
