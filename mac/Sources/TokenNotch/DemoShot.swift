import AppKit
import SwiftUI

/// `TokenNotch --demo-shot out-folder` draws the README's pictures: the open notch over a plain
/// backdrop, filled with DemoData's made-up numbers, and the closed notch with each choice of what it
/// shows. Nothing is read from this computer.
@MainActor
enum DemoShot {
    struct Shot {
        let name: String
        let setup: String  // run in the page before the picture is taken
    }

    static let shots = [
        Shot(name: "overview", setup: "notch.show({tool: 'claude', tab: 'overview', range: '30', theme: 'ocean', more: false})"),
        Shot(name: "models", setup: "notch.show({tool: 'claude', tab: 'models', range: '30', theme: 'ocean', more: false})"),
        Shot(name: "codex", setup: "notch.show({tool: 'codex', tab: 'overview', range: '30', theme: 'grape', more: false})"),
    ]

    static func run(out folder: String) {
        let json = DemoData.page()
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        let page = String(decoding: data, as: UTF8.self)
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        // Run from the repository (or mac/ in it), the page there is the one to draw.
        let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for local in [here.appendingPathComponent("dashboard.html"), here.appendingPathComponent("mac/dashboard.html")]
            where FileManager.default.fileExists(atPath: local.path) {
            DashboardWeb.template = local
            break
        }
        let snapshot = demoSnapshot(json, page: page)
        let soon = Date().addingTimeInterval(4 * 3600)
        let plan = PlanUsage(fiveHour: .init(percent: 42, resetsAt: soon.addingTimeInterval(-6300)),
                             week: .init(percent: 61, resetsAt: soon.addingTimeInterval(3 * 86400)))
        let usage = UsageModel(snapshot: snapshot, plan: plan)

        // The page needs a window to draw into; this one sits off screen.
        let web = DashboardWeb()
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: NotchState.openWidth, height: 800),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = web.view
        window.orderFrontRegardless()
        var pageHeight: CGFloat = 480
        web.onHeight = { pageHeight = $0 }
        web.load(page)
        web.setLimits(Limits.json(snapshot, plan: plan, failure: nil))
        spin(3)

        for shot in shots {
            web.view.evaluateJavaScript(shot.setup) { _, error in
                if let error { print("\(shot.name): \(error)") }
            }
            spin(1.5)
            // Fit the page's frame to its height until it stops changing: the page lays out a little
            // differently while it overflows its frame.
            for _ in 0..<4 {
                web.view.evaluateJavaScript("notch.height()") { value, _ in
                    if let height = value as? NSNumber { pageHeight = CGFloat(height.doubleValue) }
                }
                spin(0.5)
                if abs(web.view.frame.height - pageHeight) < 1 { break }
                web.view.setFrameSize(NSSize(width: NotchState.openWidth, height: pageHeight))
                spin(1)
            }
            var done = false
            web.captureStill { done = true }
            while !done { spin(0.1) }

            let state = NotchState()
            state.expanded = true
            state.progress = 1
            state.pageHeight = pageHeight
            let island = GenieIsland(progress: 1, pageHeight: pageHeight, usage: usage, state: state, web: web) {}
            write(backdrop(island, height: state.height + NotchState.pageGap + pageHeight + 2 * NotchState.margin),
                  to: "\(folder)/\(shot.name).png")
        }

        // The closed notch, once per choice.
        let closed = VStack(spacing: 0) {
            ForEach(NotchShows.allCases, id: \.self) { shows in
                let defaults = UserDefaults(suiteName: "TokenNotch.demo.\(shows.rawValue)")!
                let _ = defaults.set(shows.rawValue, forKey: "notchShows")
                let state = NotchState()
                let _ = state.textWidth = 44
                ZStack(alignment: .top) {
                    NotchView(usage: usage, state: state) {}.defaultAppStorage(defaults)
                    Text(shows.title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                        .padding(.top, 44)
                }
                .frame(width: 420, height: 72, alignment: .top)
                .background(wallpaper)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(8)
            }
        }
        write(closed, to: "\(folder)/notch.png")
    }

    /// The numbers the closed notch needs, taken from the page data.
    private static func demoSnapshot(_ json: [String: Any], page: String) -> Snapshot {
        func todayTokens(_ data: [String: Any]?) -> Int {
            guard let today = json["today"] as? String, let days = data?["days"] as? [String: Any],
                  let day = days[today] as? [String: Any], let byModel = day["tm"] as? [String: NSNumber] else { return 0 }
            return byModel.values.reduce(0) { $0 + $1.intValue }
        }
        var snapshot = Snapshot()
        snapshot.today = [todayTokens(json), 0, 0, 0]
        let codex = json["codex"] as? [String: Any]
        snapshot.codexToday = todayTokens(codex)
        snapshot.codexLimits = codex?["limits"] as? [[String: Any]] ?? []
        snapshot.active = Tool(rawValue: json["active"] as? String ?? "") ?? .claude
        snapshot.page = page
        return snapshot
    }

    /// Soft colors standing in for a desktop picture behind the glass.
    private static var wallpaper: some View {
        LinearGradient(colors: [Color(red: 0.16, green: 0.32, blue: 0.62), Color(red: 0.45, green: 0.30, blue: 0.62),
                                Color(red: 0.85, green: 0.52, blue: 0.45)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private static func backdrop(_ island: some View, height: CGFloat) -> some View {
        island
            .frame(width: NotchState.openWidth + 2 * NotchState.margin, height: height, alignment: .top)
            .background(wallpaper)
    }

    private static func write(_ view: some View, to path: String) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            print("couldn't draw \(path)"); return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
        } catch {
            print("couldn't write \(path): \(error.localizedDescription)")
        }
    }

    private static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
