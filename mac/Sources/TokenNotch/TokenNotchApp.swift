import SwiftUI

@main
enum Main {
    static func main() {
        // `TokenNotch --print` prints the numbers and exits.
        if CommandLine.arguments.contains("--print") {
            let s = TranscriptReader().snapshot()
            print("all time: \(s.allTime) tokens, \(s.responses) responses")
            print("today: \(s.todayTotal) \(s.today)")
            for (day, tokens) in s.week { print("  \(day.formatted(date: .numeric, time: .omitted)): \(tokens)") }
            if let w = s.window { print("window: \(w.start) – \(w.end), \(w.tokens) tokens") }
            if let q = s.limit { print("limit: \(q.status) until \(q.resetsAt)") }
            print("open at login: \(LoginItem.enabled)")
            switch PlanUsage.fetch() {
            case .success(let plan):
                for (name, limit) in [("5-hour", plan.fiveHour), ("weekly", plan.week)] {
                    if let limit { print("\(name) limit: \(Int(limit.percent.rounded()))% used, resets \(limit.resetsAt.map { "\($0)" } ?? "?")") }
                }
            case .failure(let failure):
                print("plan limits: \(failure.message)")
            }
            // `--page out.json` also writes the page data the dashboard is filled with.
            if let i = CommandLine.arguments.firstIndex(of: "--page"), i + 1 < CommandLine.arguments.count {
                try? s.page.write(toFile: CommandLine.arguments[i + 1], atomically: true, encoding: .utf8)
            }
            return
        }
        // `TokenNotch --snapshot out.png` renders the closed notch and the menu bar panel with your numbers.
        // (The open notch shows a web page, which the renderer can't draw.)
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let plan = try? PlanUsage.fetch().get()
            let usage = UsageModel(snapshot: TranscriptReader().snapshot(), plan: plan)
            let views = VStack(spacing: 24) {
                // The closed notch with each choice of what it shows.
                ForEach(NotchShows.allCases, id: \.self) { shows in
                    let closed = NotchState()
                    let defaults = UserDefaults(suiteName: "TokenNotch.snapshot.\(shows.rawValue)")!
                    let _ = defaults.set(shows.rawValue, forKey: "notchShows")
                    NotchView(usage: usage, state: closed) {}
                        .defaultAppStorage(defaults)
                        .frame(width: 680, height: 40, alignment: .top).clipped()
                }
                // The mark large and at a few moments of its animation.
                HStack(spacing: 16) {
                    ClaudeMark(size: 96, animated: false)
                    CodexMark(size: 96, animated: false)
                    CodexMark(size: 16, animated: false)
                    ForEach([0.0, 0.4, 0.8, 1.2], id: \.self) { t in ClaudeMark(size: 48, frozenAt: t) }
                    ClaudeMark(size: 16, animated: false)
                }
                .padding(12).background(Color.black)
                // The island's outline at points through the opening.
                HStack(alignment: .top, spacing: 8) {
                    ForEach([0.15, 0.3, 0.45, 0.6, 0.8, 1.0], id: \.self) { (p: CGFloat) in
                        GenieShape(genie: Genie(progress: p, closed: CGSize(width: 270, height: 32),
                                                open: CGSize(width: 600, height: 560)))
                            .fill(Color.black)
                            .frame(width: 600, height: 580)
                            .scaleEffect(0.25, anchor: .topLeading)
                            .frame(width: 150, height: 145, alignment: .topLeading)
                    }
                }
                UsagePanel(usage: usage).background(Color(nsColor: .windowBackgroundColor))
            }
            .padding(24)
            .background(Color(white: 0.85))
            let renderer = ImageRenderer(content: views)
            renderer.scale = 2
            if let image = renderer.cgImage,
               let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            }
            return
        }
        // `TokenNotch --icon AppIcon.iconset` draws the app icon at every size; build-app.sh uses it.
        if let i = CommandLine.arguments.firstIndex(of: "--icon"), i + 1 < CommandLine.arguments.count {
            AppIconArt.writeIconset(to: CommandLine.arguments[i + 1])
            return
        }
        // `TokenNotch --demo-shot folder` draws the README's pictures from made-up data.
        if let i = CommandLine.arguments.firstIndex(of: "--demo-shot"), i + 1 < CommandLine.arguments.count {
            DemoShot.run(out: CommandLine.arguments[i + 1])
            return
        }
        TokenNotchApp.main()
    }
}

struct TokenNotchApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var usage = UsageModel.shared
    @StateObject private var screens = Screens()
    @AppStorage("notchShows") private var shows = NotchShows.tokens

    var body: some Scene {
        // The notch shows everything on a Mac that has one; the menu bar item is for those that don't.
        MenuBarExtra(isInserted: .constant(!screens.notched)) {
            UsagePanel(usage: usage)
        } label: {
            // The menu bar shows today's tokens, or a limit's percentage, beside the icon.
            if usage.snapshot?.active == .codex {
                Image(nsImage: CodexMark.menuBarImage)
            } else if usage.snapshot?.limit == nil {
                Image(nsImage: ClaudeMark.menuBarImage)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            Text(NotchView.label(usage.snapshot, plan: usage.plan, shows: shows))
        }
        .menuBarExtraStyle(.window)
    }
}

/// Whether any screen has a notch, kept current as displays come and go.
final class Screens: ObservableObject {
    @Published private(set) var notched = Screens.check()
    private var observer: Any?

    init() {
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.notched = Screens.check()
        }
    }

    private static func check() -> Bool { NSScreen.screens.contains { $0.safeAreaInsets.top > 0 } }
}

/// Puts the island on the notch; the menu bar item stays for screens without one.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notch: NotchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        notch = NotchController(usage: .shared)
        LoginItem.enableOnFirstLaunch()
    }
}

/// Rereads the transcripts every minute, off the main thread; only new bytes are read after the first time.
final class UsageModel: ObservableObject {
    /// The one the menu bar item and the notch share.
    static let shared = UsageModel()

    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var loading = false
    @Published private(set) var plan: PlanUsage?
    @Published private(set) var planFailure: PlanUsage.Failure?
    private var planFetched = Date.distantPast
    private let reader = TranscriptReader()
    private let queue = DispatchQueue(label: "TokenNotch.scan", qos: .utility)
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    /// Fixed numbers and no timer, for --snapshot.
    init(snapshot: Snapshot, plan: PlanUsage? = nil) {
        self.snapshot = snapshot
        self.plan = plan
    }

    func refresh() {
        guard timer != nil || snapshot == nil else { return }
        reload()
    }

    private func reload() {
        guard !loading else { return }
        loading = true
        // Plan limits are asked for at most every two minutes; the transcripts are read every time.
        let askPlan = Date().timeIntervalSince(planFetched) > 120
        if askPlan { planFetched = Date() }
        queue.async { [reader] in
            let snap = reader.snapshot()
            let plan = askPlan ? PlanUsage.fetch() : nil
            DispatchQueue.main.async {
                self.snapshot = snap
                switch plan {
                case .success(let usage): self.plan = usage; self.planFailure = nil
                case .failure(let failure): self.planFailure = failure
                case nil: break
                }
                self.loading = false
            }
        }
    }
}

enum Format {
    static func tokens(_ n: Int) -> String {
        let v = Double(n)
        for (unit, suffix) in [(1e9, "B"), (1e6, "M"), (1e3, "K")] where v >= unit {
            // 24M, not 24.0M; 15.6B keeps its decimal.
            let number = String(format: v / unit >= 100 ? "%.0f" : "%.1f", v / unit)
            return (number.hasSuffix(".0") ? String(number.dropLast(2)) : number) + suffix
        }
        return "\(n)"
    }

    /// claude-opus-5-5 → "Opus 5.5"; a trailing date or [1m] is dropped, so claude-sonnet-4-5-20250929 →
    /// "Sonnet 4.5". Anything else keeps its ID. The dashboard names models the same way.
    static func model(_ id: String) -> String {
        let bare = id.firstIndex(of: "[").map { String(id[..<$0]) } ?? id
        let parts = bare.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count > 2, parts[0] == "claude", !parts[1].isEmpty, parts[1].allSatisfy({ $0.isLetter && $0.isLowercase })
        else { return id }
        let version = parts.dropFirst(2).prefix { $0.count <= 2 && !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
        return version.isEmpty ? id : parts[1].capitalized + " " + version.joined(separator: ".")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}
