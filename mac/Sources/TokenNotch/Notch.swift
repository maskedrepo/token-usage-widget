import AppKit
import Combine
import SwiftUI
import WebKit

/// The notch's size and whether it is open. Closed, the island is the notch plus a black wing
/// either side; both wings are as wide as the wider one needs, so the island stays centered.
final class NotchState: ObservableObject {
    @Published var expanded = false
    @Published var progress: CGFloat = 0  // 0 closed, 1 open; animated, it drives the genie morph
    @Published var live = false           // open and settled: the real page shows instead of its picture
    @Published var hovering = false
    @Published var textWidth: CGFloat = 40  // today's number, measured in the wing's font
    @Published var pageHeight: CGFloat = 480  // reported by the page, so the island fits it without scrolling
    var maxPageHeight: CGFloat = 760
    var notchWidth: CGFloat = 185
    var height: CGFloat = 32

    static let icon: CGFloat = 16
    static let inner: CGFloat = 6   // gap between the notch and a wing's content
    static let outer: CGFloat = 10  // gap between a wing's content and its outer edge
    static let hoverGrow: CGFloat = 4
    static let openWidth: CGFloat = 600   // wide enough for the page's four-across tiles
    static let pageGap: CGFloat = 4       // between the wing row and the page
    static let margin: CGFloat = 40       // clear room around the open island for its shadow
    // Open pours out with a little bounce at the bottom; close is drawn back in without one.
    static let open = Animation.spring(response: 0.62, dampingFraction: 0.76)
    static let close = Animation.spring(response: 0.5, dampingFraction: 0.92)
    static let resize = Animation.spring(response: 0.45, dampingFraction: 0.9)

    private var grow: CGFloat { hovering && !expanded ? Self.hoverGrow : 0 }
    var wing: CGFloat { max(Self.outer + Self.icon + Self.inner, Self.inner + textWidth + Self.outer) + grow }
    var closedWidth: CGFloat { notchWidth + 2 * wing }
    var closedHeight: CGFloat { height + grow }
}

/// A borderless panel above the menu bar, centered on the notch. It never resizes: closed, clicks
/// pass through everywhere except the island. On a screen without a notch it is a pill at the top center.
final class NotchController {
    private let state = NotchState()
    private let usage: UsageModel
    private let web = DashboardWeb()
    private let panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
    private var monitors: [Any] = []
    private var clickOutside: Any?
    private var updates: AnyCancellable?
    private var limitUpdates: AnyCancellable?
    private var labelUpdates: AnyCancellable?
    private var notchCenter: CGFloat = 0
    private var top: CGFloat = 0

    init(usage: UsageModel) {
        self.usage = usage
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = FirstClickHostingView(rootView: NotchView(usage: usage, state: state, web: web) { [weak self] in
            self?.toggle()
        })
        place()
        panel.orderFrontRegardless()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.place() }
        web.onHeight = { [weak self] height in
            guard let self else { return }
            let fitted = min(height, self.state.maxPageHeight)
            guard abs(fitted - self.state.pageHeight) > 0.5 else { return }
            if self.state.expanded {
                withAnimation(NotchState.resize) { self.state.pageHeight = fitted }
            } else {
                self.state.pageHeight = fitted
                // Retake the page's picture once it has laid out at its new height.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.web.captureStill() }
            }
        }
        // The plan's limits go into the page, under the contribution graph.
        limitUpdates = Publishers.CombineLatest3(usage.$snapshot, usage.$plan, usage.$planFailure)
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot, plan, failure in
                guard let self, let snapshot else { return }
                self.web.setLimits(Limits.json(snapshot, plan: plan, failure: failure))
            }
        updates = usage.$snapshot.receive(on: RunLoop.main).sink { [weak self] snapshot in
            guard let self, let snapshot else { return }
            // Load new numbers while closed, so the page is ready the moment the island opens.
            if !self.state.expanded && self.state.progress == 0 { self.web.load(snapshot.page) }
        }
        // The wings fit whatever the notch shows: today's tokens or a limit's percentage.
        labelUpdates = Publishers.CombineLatest3(usage.$snapshot, usage.$plan, UserDefaults.standard.publisher(for: \.notchShows))
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot, plan, shows in
                self?.state.textWidth = Self.textWidth(NotchView.label(snapshot, plan: plan, shows: NotchShows(rawValue: shows) ?? .tokens))
            }
        // Hover and click-through follow the pointer, wherever it is.
        let track: (NSEvent) -> Void = { [weak self] _ in self?.trackPointer() }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: track) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { track($0); return $0 }) { monitors.append(m) }
    }

    /// Width of the wing's text in the font NotchView draws it with.
    private static func textWidth(_ text: String) -> CGFloat {
        let base = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 12) } ?? base
        return ceil((text as NSString).size(withAttributes: [.font: font]).width) + 1
    }

    private func place() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            state.notchWidth = screen.frame.width - left.width - right.width
            state.height = screen.safeAreaInsets.top
            notchCenter = screen.frame.minX + left.width + state.notchWidth / 2
        } else {
            state.notchWidth = 0
            state.height = screen.frame.maxY - screen.visibleFrame.maxY
            notchCenter = screen.frame.midX
        }
        top = screen.frame.maxY
        let width = NotchState.openWidth + 2 * NotchState.margin
        let height = min(screen.frame.height - 40, state.height + NotchState.pageGap + 760 + 2 * NotchState.margin)
        state.maxPageHeight = height - state.height - NotchState.pageGap - 2 * NotchState.margin
        panel.setFrame(NSRect(x: notchCenter - width / 2, y: top - height, width: width, height: height), display: true)
    }

    private func trackPointer() {
        guard !state.expanded else { return }
        let island = NSRect(x: notchCenter - state.closedWidth / 2, y: top - state.closedHeight,
                            width: state.closedWidth, height: state.closedHeight)
        let over = island.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
        if over != state.hovering {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.62)) { state.hovering = over }
        }
        panel.ignoresMouseEvents = !over
    }

    func toggle() {
        if state.expanded { collapse() } else { expand() }
    }

    private func expand() {
        panel.ignoresMouseEvents = false
        panel.makeKey()  // so the page takes clicks and scrolling straight away
        state.hovering = false
        state.expanded = true
        // The page's picture morphs out with the island; the live page takes over once it settles.
        withAnimation(NotchState.open) {
            state.progress = 1
        } completion: { [state] in
            if state.expanded { state.live = true }
        }
        clickOutside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.collapse()
        }
    }

    private func collapse() {
        guard state.expanded else { return }
        if let monitor = clickOutside { NSEvent.removeMonitor(monitor) }
        clickOutside = nil
        state.expanded = false
        // Picture the page as it is now (tab, theme, stats), then draw that back into the notch.
        web.captureStill { [weak self] in
            guard let self, !self.state.expanded else { return }
            self.state.live = false
            withAnimation(NotchState.close) {
                self.state.progress = 0
            } completion: { [weak self] in
                guard let self, !self.state.expanded else { return }
                self.trackPointer()
                if let page = self.usage.snapshot?.page { self.web.load(page) }
            }
        }
    }
}

/// A panel that can take clicks and scrolling without activating the app.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Lets the first click land on the island even though the app is never active.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct NotchView: View {
    @ObservedObject var usage: UsageModel
    @ObservedObject var state: NotchState
    var web: DashboardWeb?
    let toggle: () -> Void

    /// Today's tokens, or a limit's percentage without its name: the notch has no room for one.
    static func label(_ snapshot: Snapshot?, plan: PlanUsage?, shows: NotchShows) -> String {
        guard let snapshot else { return "…" }
        if shows == .tokens { return Format.tokens(snapshot.activeToday) }
        return snapshot.percentUsed(shows, plan: plan).map(Limits.percent) ?? "–%"
    }

    /// White while there's room; a limit turns orange from 80% and red from 95%.
    static func labelColor(_ snapshot: Snapshot?, plan: PlanUsage?, shows: NotchShows) -> Color {
        guard shows != .tokens, let percent = snapshot?.percentUsed(shows, plan: plan), percent >= 80 else { return .white }
        return Limits.color(percent)
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Clicks on the clear part of the open window close it.
            if state.expanded { Color.clear.contentShape(Rectangle()).onTapGesture(perform: toggle) }
            GenieIsland(progress: state.progress, pageHeight: state.pageHeight,
                        usage: usage, state: state, web: web, toggle: toggle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The island at any point between closed and open. SwiftUI animates `progress` and `pageHeight`
/// and redraws this every frame, so the outline, the page's picture and the strip morph together.
struct GenieIsland: View, Animatable {
    var progress: CGFloat
    var pageHeight: CGFloat
    let usage: UsageModel
    let state: NotchState
    let web: DashboardWeb?
    let toggle: () -> Void
    @AppStorage("notchShows") private var shows = NotchShows.tokens

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(progress, pageHeight) }
        set { progress = newValue.first; pageHeight = newValue.second }
    }

    private var open: CGSize {
        CGSize(width: NotchState.openWidth, height: state.height + NotchState.pageGap + pageHeight)
    }
    private var genie: Genie {
        Genie(progress: progress, closed: CGSize(width: state.closedWidth, height: state.closedHeight), open: open)
    }
    private var settled: CGFloat { min(1, max(0, progress)) }
    /// The content fades in early in the opening and out at the very end of the closing.
    private var shown: CGFloat { smoothstep(0.03, 0.35, progress) }

    var body: some View {
        let genie = self.genie
        let shape = GenieShape(genie: genie)
        let warping = !state.live
        ZStack(alignment: .top) {
            shadow(shape)
            IslandSurface(shape: shape, glass: settled)
            // The wing row stays solid black, like the notch it grows from, and fades into the glass
            // below; this also hides the glass's lit rim along the top edge of the screen.
            shape.fill(LinearGradient(stops: [.init(color: .black, location: 0),
                                              .init(color: .black, location: state.height / frameHeight),
                                              .init(color: .clear, location: (state.height + 18) / frameHeight)],
                                      startPoint: .top, endPoint: .bottom))
            content(genie, warping: warping)
            if warping, let still = web?.still {
                GenieWarp(image: still, genie: genie, top: state.height + NotchState.pageGap, height: pageHeight)
                    .opacity(shown)
                    .allowsHitTesting(false)
            }
            wings(genie)
        }
        .frame(width: open.width, height: frameHeight, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    private var frameHeight: CGFloat { open.height + NotchState.margin }

    /// A soft shadow under the island that starts below the menu bar, so none spills onto it.
    private func shadow(_ shape: GenieShape) -> some View {
        let room = NotchState.margin
        return shape.fill(Color.black.opacity(0.5 * settled))
            .frame(width: open.width, height: frameHeight)
            .blur(radius: 22)
            .offset(y: 14)
            .padding(.horizontal, room)
            .padding(.bottom, room)
            .mask(alignment: .top) {
                VStack(spacing: 0) { Color.clear.frame(height: state.height + 8); Color.black }
            }
            .padding(.horizontal, -room)
            .padding(.bottom, -room)
            .allowsHitTesting(false)
    }

    /// The page, laid out where it sits when open. While the island moves, the live page stays
    /// hidden behind its picture.
    private func content(_ genie: Genie, warping: Bool) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: state.height + NotchState.pageGap)
            Group {
                // Always in the window, so it is drawn and ready; seen only once the island settles.
                if let web { DashboardPage(web: web).opacity(state.live ? 1 : (web.still == nil ? shown : 0)) }
            }
            .frame(height: pageHeight)
        }
        .frame(width: open.width)
    }

    /// The strip level with the notch: the tool's mark on the left, the chosen number on the right.
    private func wings(_ genie: Genie) -> some View {
        HStack(spacing: 0) {
            // The mark of the tool in use; a warning while Claude Code's limit is reached.
            ZStack {
                if usage.snapshot?.active == .codex {
                    CodexMark(size: 16).transition(.opacity)
                } else if usage.snapshot?.limit != nil {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.orange)
                } else {
                    ClaudeMark(size: 16).transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.35), value: usage.snapshot?.active)
            .frame(width: NotchState.icon)
            .padding(.leading, NotchState.outer)
            .frame(width: state.wing, alignment: .leading)
            Spacer(minLength: state.notchWidth)
            // Closed, today's tokens or a limit's percentage; open, when the numbers were read.
            ZStack(alignment: .trailing) {
                Text(NotchView.label(usage.snapshot, plan: usage.plan, shows: shows))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(NotchView.labelColor(usage.snapshot, plan: usage.plan, shows: shows))
                    .opacity(1 - settled)
                if let updated = usage.snapshot?.updated {
                    Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .opacity(settled)
                }
            }
            .fixedSize()
            .padding(.trailing, NotchState.outer + 4 * settled)
            .frame(width: state.wing, alignment: .trailing)
        }
        .frame(width: genie.width(atDepth: 0),
               height: state.closedHeight + (state.height - state.closedHeight) * settled)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .contextMenu { IslandMenu(usage: usage) }
    }
}

/// Right-click on the notch: what the menu bar item's panel offers, for Macs where it is hidden.
struct IslandMenu: View {
    let usage: UsageModel
    @AppStorage("animateIcon") private var animateIcon = true
    @AppStorage("notchShows") private var shows = NotchShows.tokens

    var body: some View {
        Picker("Notch shows", selection: $shows) {
            ForEach(NotchShows.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        Toggle("Animate icon", isOn: $animateIcon)
        Toggle("Open at login", isOn: LoginItem.binding)
        Button("Refresh now") { usage.refresh() }
        Divider()
        Button("Quit Token Notch") { NSApp.terminate(nil) }
    }
}

func smoothstep(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat {
    let t = min(1, max(0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)
}

/// The island's outline partway open, like the Dock's genie effect run out of the notch: the
/// bottom pours down and widens first, the neck at the notch widens last. Closing runs it backwards.
struct Genie {
    var progress: CGFloat
    var closed: CGSize
    var open: CGSize

    var radius: CGFloat { 10 + 18 * min(1, max(0, progress)) }
    /// Full height comes early; past 1 (the spring's overshoot) the bottom bounces a little lower.
    var height: CGFloat {
        let p = progress < 1 ? min(1, progress * 1.25) : progress
        return closed.height + (open.height - closed.height) * p
    }
    /// How much the open content is squeezed vertically.
    var squash: CGFloat { height / open.height }
    private var corner: CGFloat { min(radius, width(atDepth: 1) / 2, height / 2) }

    /// Width at a depth from 0 (the notch) to 1 (the bottom).
    func width(atDepth t: CGFloat) -> CGFloat {
        let s = smoothstep(0, 1, progress * 1.7 - 0.7 * (1 - smoothstep(0, 1, t)))
        return closed.width + (open.width - closed.width) * s
    }

    func width(atY y: CGFloat) -> CGFloat { width(atDepth: min(1, max(0, y / max(1, height - corner)))) }

    func path(midX: CGFloat) -> Path {
        let rows = 32, r = corner, side = height - r
        var path = Path()
        path.move(to: CGPoint(x: midX + width(atDepth: 0) / 2, y: 0))
        path.addLine(to: CGPoint(x: midX - width(atDepth: 0) / 2, y: 0))
        for i in 1...rows {
            let t = CGFloat(i) / CGFloat(rows)
            path.addLine(to: CGPoint(x: midX - width(atDepth: t) / 2, y: side * t))
        }
        let half = width(atDepth: 1) / 2
        path.addQuadCurve(to: CGPoint(x: midX - half + r, y: height), control: CGPoint(x: midX - half, y: height))
        path.addLine(to: CGPoint(x: midX + half - r, y: height))
        path.addQuadCurve(to: CGPoint(x: midX + half, y: side), control: CGPoint(x: midX + half, y: height))
        for i in stride(from: rows - 1, through: 1, by: -1) {
            let t = CGFloat(i) / CGFloat(rows)
            path.addLine(to: CGPoint(x: midX + width(atDepth: t) / 2, y: side * t))
        }
        path.closeSubpath()
        return path
    }
}

struct GenieShape: Shape {
    var genie: Genie
    func path(in rect: CGRect) -> Path { genie.path(midX: rect.midX) }
}

/// A picture of the page bent to the outline: cut into thin rows, each squeezed to the island's
/// width at the height it is drawn.
struct GenieWarp: View {
    let image: NSImage
    let genie: Genie
    let top: CGFloat     // where the page starts, open
    let height: CGFloat  // the page's height, open
    @Environment(\.displayScale) private var scale

    var body: some View {
        Canvas { context, size in
            let picture = context.resolve(Image(nsImage: image))
            let rows = 40, k = genie.squash, row = height / CGFloat(rows)
            // Rows meet exactly on screen pixels: an overlap draws the page's see-through tiles twice
            // (a bright line), a gap leaves a dark one.
            let pixel = { (y: CGFloat) in (y * scale).rounded() / scale }
            for i in 0..<rows {
                let y0 = pixel((top + row * CGFloat(i)) * k), y1 = pixel((top + row * CGFloat(i + 1)) * k)
                guard y1 > y0 else { continue }
                let width = genie.width(atY: (y0 + y1) / 2)
                let x = (size.width - width) / 2
                context.drawLayer { layer in
                    layer.clip(to: Path(CGRect(x: x, y: y0, width: width, height: y1 - y0)))
                    layer.draw(picture, in: CGRect(x: x, y: top * k, width: width, height: height * k))
                }
            }
        }
    }
}

/// The plan's limits for the row under the page's contribution graph: the five-hour limit with
/// its reset, and the weekly limit beside it. Without the account's numbers it falls back to the
/// transcripts' five-hour window.
enum Limits {
    static func json(_ s: Snapshot, plan: PlanUsage?, failure: PlanUsage.Failure?) -> String {
        let row = data(s, plan: plan, failure: failure)
        guard let json = try? JSONSerialization.data(withJSONObject: row) else { return "null" }
        return String(decoding: json, as: UTF8.self)
    }

    static func data(_ s: Snapshot, plan: PlanUsage?, failure: PlanUsage.Failure?) -> [String: Any] {
        let time = { (date: Date) in date.formatted(date: .omitted, time: .shortened) }
        let note = failure?.message ?? ""
        if let five = plan?.fiveHour {
            var row: [String: Any] = ["label": "5-hour", "value": percent(five.percent),
                                      "fraction": five.percent / 100, "level": level(five.percent)]
            if let reset = five.resetsAt {
                row["detail"] = "\(time(reset)) · in \(Format.duration(reset.timeIntervalSinceNow))"
                row["tip"] = "The 5-hour limit resets at \(time(reset))"
            }
            if let week = plan?.week {
                row["side"] = ["label": "Weekly", "value": percent(week.percent), "level": level(week.percent),
                               "tip": week.resetsAt.map { "Resets \($0.formatted(.dateTime.weekday(.wide).hour().minute()))" } ?? ""]
            }
            return row
        }
        if let q = s.limit {
            return ["label": "5-hour", "value": "Limit reached", "fraction": 1, "level": "over",
                    "detail": "resets \(time(q.resetsAt))", "note": note]
        }
        guard let w = s.window else {
            return ["label": "5-hour window", "value": "–", "fraction": 0, "detail": "starts with your next message", "note": note]
        }
        return ["label": "5-hour window", "value": Format.tokens(w.tokens),
                "fraction": s.updated.timeIntervalSince(w.start) / TranscriptReader.windowLength,
                "detail": "resets \(time(w.end)) · in \(Format.duration(w.end.timeIntervalSince(s.updated)))", "note": note]
    }

    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    static func level(_ percent: Double) -> String { percent >= 95 ? "over" : percent >= 80 ? "warn" : "" }

    /// Blue while there's room, orange from 80%, red from 95%.
    static func color(_ percent: Double) -> Color {
        percent >= 95 ? .red : percent >= 80 ? .orange : UsagePanel.accent
    }
}

/// A thin capsule filled to a fraction.
struct Meter: View {
    var fraction: Double
    var color: Color

    var body: some View {
        Capsule().fill(Color.primary.opacity(0.15))
            .overlay(alignment: .leading) {
                GeometryReader { g in Capsule().fill(color).frame(width: g.size.width * min(1, max(0, fraction))) }
            }
            .frame(height: 5)
    }
}

/// The web dashboard itself (dashboard.html with this computer's data), on a clear background.
/// One web view lives for the whole run and is loaded while the island is closed, so opening shows
/// a finished page at once. The page reports its height, so the island fits it without scrolling.
final class DashboardWeb: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let view: WKWebView
    var onHeight: ((CGFloat) -> Void)?
    /// The page's latest picture, which morphs while the island opens and closes.
    private(set) var still: NSImage?
    private var loaded: String?
    private var limits = "null"
    private var animateSetting: NSKeyValueObservation?
    private var notchSetting: NSKeyValueObservation?

    override init() {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        config.userContentController = controller
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: NotchState.openWidth, height: 480), configuration: config)
        super.init()
        controller.add(WeakHandler(self), name: "height")
        controller.add(WeakHandler(self), name: "animateIcon")
        controller.add(WeakHandler(self), name: "notchShows")
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = self
        // The right-click menu changes this too; keep the page's checkmark in step.
        animateSetting = UserDefaults.standard.observe(\.animateIcon) { [weak self] _, _ in
            DispatchQueue.main.async { self?.showAnimateSetting() }
        }
        notchSetting = UserDefaults.standard.observe(\.notchShows) { [weak self] _, _ in
            DispatchQueue.main.async { self?.showAnimateSetting() }
        }
    }

    func load(_ page: String) {
        guard page != loaded else { return }
        loaded = page
        // A fixed https origin so the page keeps its theme, tab and range choices between loads.
        view.loadHTMLString(Self.html(page), baseURL: URL(string: "https://token-usage.local/"))
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "animateIcon", let on = message.body as? Bool {
            UserDefaults.standard.set(on, forKey: "animateIcon")
        } else if message.name == "notchShows", let shows = message.body as? String, NotchShows(rawValue: shows) != nil {
            UserDefaults.standard.set(shows, forKey: "notchShows")
        } else if let height = message.body as? NSNumber {
            onHeight?(CGFloat(height.doubleValue))
        }
    }

    func setLimits(_ json: String) {
        guard json != limits else { return }
        limits = json
        view.evaluateJavaScript("notch.limits(\(json))") { [weak self] _, _ in self?.measure() }
    }

    /// The page's height, asked directly: its own observer only runs while it is on screen.
    private func measure() {
        view.evaluateJavaScript("notch.height()") { [weak self] value, _ in
            if let height = value as? NSNumber { self?.onHeight?(CGFloat(height.doubleValue)) }
            // Once the charts have drawn, picture it for the next opening.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.captureStill() }
        }
    }

    func captureStill(then done: (() -> Void)? = nil) {
        view.takeSnapshot(with: nil) { [weak self] image, _ in
            if let image { self?.still = image }
            done?()
        }
    }

    /// The app's settings in the page's menu, kept in step with the right-click menu.
    private func showAnimateSetting() {
        view.evaluateJavaScript("notch.settings({animate: \(UserDefaults.standard.animateIcon), shows: '\(UserDefaults.standard.notchShows)'})")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        showAnimateSetting()
        webView.evaluateJavaScript("notch.limits(\(limits))") { [weak self] _, _ in self?.measure() }
    }

    /// The page, from the app's resources; --demo-shot points it at the repository's copy.
    static var template = Bundle.main.url(forResource: "dashboard", withExtension: "html")

    static func html(_ page: String) -> String {
        guard let url = template,
              let template = try? String(contentsOf: url, encoding: .utf8) else {
            return "<p style='color:#fff;font:13px system-ui'>dashboard.html is missing from the app. Build it with mac/build-app.sh.</p>"
        }
        return template.replacingOccurrences(of: "/*PAGE_DATA*/null", with: page)
    }
}

extension UserDefaults {
    /// Whether the Claude icon animates; observable, unlike @AppStorage.
    @objc dynamic var animateIcon: Bool { object(forKey: "animateIcon") as? Bool ?? true }
    /// A NotchShows raw value.
    @objc dynamic var notchShows: String { string(forKey: "notchShows") ?? NotchShows.tokens.rawValue }
}

/// WebKit keeps its message handlers alive; this keeps it from keeping DashboardWeb alive too.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

struct DashboardPage: NSViewRepresentable {
    let web: DashboardWeb
    func makeNSView(context: Context) -> WKWebView { web.view }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

/// Solid black while closed so it reads as part of the notch; opening, dark Liquid Glass fades in
/// underneath (macOS 26 and later) so the desktop shows through a little.
struct IslandSurface<S: Shape>: View {
    var shape: S
    var glass: CGFloat  // 0 closed, 1 open

    var body: some View {
        ZStack {
            if #available(macOS 26, *), glass > 0.01 {
                Color.clear.glassEffect(.regular.tint(.black.opacity(0.3)), in: shape).opacity(glass)
            }
            shape.fill(Color.black.opacity(1 - 0.58 * glass))
        }
    }
}

/// Claude's starburst, drawn in code: twelve tapered rays with rounded tips, a little uneven on
/// purpose. Animated, a swell runs around the rays while the mark turns slowly; still when turned
/// off or with Reduce Motion.
struct ClaudeMark: View {
    var size: CGFloat
    var animated = true
    var frozenAt: TimeInterval?  // a fixed moment of the animation, for --snapshot
    @AppStorage("animateIcon") private var animate = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let orange = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
    // Angle in degrees, then length and tip radius as fractions of the mark's radius.
    private static let rays: [(angle: Double, length: CGFloat, tip: CGFloat)] = [
        (0, 1, 0.1), (31, 0.8, 0.09), (59, 0.95, 0.1), (89, 0.72, 0.085), (119, 0.98, 0.1), (149, 0.8, 0.09),
        (180, 0.93, 0.1), (211, 0.75, 0.085), (239, 1, 0.1), (269, 0.82, 0.09), (299, 0.92, 0.1), (329, 0.77, 0.085),
    ]

    var body: some View {
        if let frozenAt {
            mark(time: frozenAt)
        } else if animated && animate && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                mark(time: context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            mark(time: nil)
        }
    }

    private func mark(time: TimeInterval?) -> some View {
        Canvas { context, canvas in
            let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            let radius = canvas.width / 2
            let turn = (time ?? 0).truncatingRemainder(dividingBy: 360) * 0.4
            var burst = Path()
            for (i, ray) in Self.rays.enumerated() {
                // A swell runs around the mark: each ray grows a little as it passes.
                let phase = Double(i) / Double(Self.rays.count) * 2 * Double.pi
                let swell: CGFloat = time.map { t -> CGFloat in CGFloat(0.5 + 0.5 * sin(t * 3.2 - phase)) } ?? 1
                let tip = radius * ray.tip
                let length = radius * ray.length * (0.78 + 0.22 * swell)
                let base = radius * 0.08
                let angle: Double = ray.angle * Double.pi / 180 + turn
                let along = CGVector(dx: cos(angle), dy: sin(angle))
                let across = CGVector(dx: -along.dy, dy: along.dx)
                let end = CGPoint(x: center.x + along.dx * (length - tip), y: center.y + along.dy * (length - tip))
                burst.move(to: CGPoint(x: center.x + across.dx * base, y: center.y + across.dy * base))
                burst.addLine(to: CGPoint(x: end.x + across.dx * tip, y: end.y + across.dy * tip))
                burst.addArc(center: end, radius: tip, startAngle: .radians(angle + .pi / 2),
                             endAngle: .radians(angle - .pi / 2), clockwise: true)
                burst.addLine(to: CGPoint(x: center.x - across.dx * base, y: center.y - across.dy * base))
                burst.closeSubpath()
            }
            context.fill(burst, with: .color(Self.orange))
        }
        .frame(width: size, height: size)
    }

    /// A still mark for the menu bar, which only shows images and text.
    @MainActor static let menuBarImage: NSImage = {
        let renderer = ImageRenderer(content: ClaudeMark(size: 16, animated: false))
        renderer.scale = 2
        return renderer.nsImage ?? NSImage()
    }()
}

/// A mark for Codex, drawn in code: a terminal prompt in a rounded square. Animated, the cursor
/// blinks; still when turned off or with Reduce Motion.
struct CodexMark: View {
    var size: CGFloat
    var animated = true
    @AppStorage("animateIcon") private var animate = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if animated && animate && !reduceMotion {
            TimelineView(.periodic(from: .now, by: 0.55)) { context in
                mark(cursor: Int(context.date.timeIntervalSinceReferenceDate / 0.55) % 2 == 0)
            }
        } else {
            mark(cursor: true)
        }
    }

    private func mark(cursor: Bool) -> some View {
        Canvas { context, canvas in
            let s = canvas.width
            let line = StrokeStyle(lineWidth: s * 0.1, lineCap: .round, lineJoin: .round)
            context.stroke(Path(roundedRect: CGRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88),
                                cornerRadius: s * 0.24), with: .color(.white), style: StrokeStyle(lineWidth: s * 0.08))
            var prompt = Path()
            prompt.move(to: CGPoint(x: s * 0.27, y: s * 0.33))
            prompt.addLine(to: CGPoint(x: s * 0.44, y: s * 0.5))
            prompt.addLine(to: CGPoint(x: s * 0.27, y: s * 0.67))
            context.stroke(prompt, with: .color(.white), style: line)
            var underscore = Path()
            underscore.move(to: CGPoint(x: s * 0.52, y: s * 0.68))
            underscore.addLine(to: CGPoint(x: s * 0.73, y: s * 0.68))
            context.stroke(underscore, with: .color(.white.opacity(cursor ? 1 : 0.25)), style: line)
        }
        .frame(width: size, height: size)
    }

    /// A still mark for the menu bar; a template image, so macOS tints it for light and dark menu bars.
    @MainActor static let menuBarImage: NSImage = {
        let renderer = ImageRenderer(content: CodexMark(size: 16, animated: false))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        return image
    }()
}
