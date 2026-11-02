import Charts
import SwiftUI

/// The panel that drops down from the menu bar icon.
struct UsagePanel: View {
    @ObservedObject var usage: UsageModel
    @AppStorage("animateIcon") private var animateIcon = true
    @AppStorage("notchShows") private var shows = NotchShows.tokens

    // Ocean, the web page's default theme.
    static let accent = Color(red: 0x2f / 255, green: 0x6f / 255, blue: 0xd6 / 255)
    static let palette: [Color] = [accent, Color(red: 0.09, green: 0.25, blue: 0.48), Color(red: 0.36, green: 0.69, blue: 0.79),
                                   Color(red: 0.49, green: 0.55, blue: 0.71), Color(red: 0.61, green: 0.44, blue: 0.82)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let s = usage.snapshot {
                if let limit = s.limit { limitBanner(limit) }
                today(s)
                window(s)
                week(s)
                if !s.todayByModel.isEmpty { models(s) }
            } else {
                ProgressView("Reading Claude Code transcripts…")
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
            footer
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { usage.refresh() }
    }

    private var header: some View {
        HStack {
            Text("Claude Code usage").font(.headline)
            Spacer()
            if usage.loading { ProgressView().controlSize(.small) }
            Button { usage.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .glassButton()
                .help("Refresh now")
        }
    }

    private func limitBanner(_ q: Quota) -> some View {
        Label("Usage limit reached · resets \(q.resetsAt.formatted(date: .omitted, time: .shortened))",
              systemImage: "exclamationmark.triangle.fill")
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange, in: RoundedRectangle(cornerRadius: 8))
    }

    private func today(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Today").font(.caption).foregroundStyle(.secondary)
            Text(Format.tokens(s.todayTotal) + " tokens")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text("In \(Format.tokens(s.today[0])) · Out \(Format.tokens(s.today[1])) · "
                 + "Cache write \(Format.tokens(s.today[2])) · Cache read \(Format.tokens(s.today[3]))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func window(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let plan = usage.plan, let five = plan.fiveHour {
                limit("5-hour limit", five)
                if let week = plan.week { limit("Weekly limit", week) }
            } else {
                windowTokens(s)
                if let failure = usage.planFailure {
                    Text(failure.message).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func limit(_ name: String, _ limit: PlanUsage.Limit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name).font(.caption).foregroundStyle(.secondary)
                Text(Limits.percent(limit.percent)).font(.callout.weight(.semibold)).monospacedDigit()
                Spacer()
                if let reset = limit.resetsAt {
                    Text("resets \(Calendar.current.isDateInToday(reset) ? reset.formatted(date: .omitted, time: .shortened) : reset.formatted(.dateTime.weekday().hour().minute()))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Meter(fraction: limit.percent / 100, color: Limits.color(limit.percent)).frame(height: 6)
        }
    }

    private func windowTokens(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Current 5-hour window").font(.caption).foregroundStyle(.secondary)
            if let w = s.window {
                HStack {
                    Text(Format.tokens(w.tokens) + " tokens").font(.callout.weight(.semibold)).monospacedDigit()
                    Spacer()
                    Text("resets \(w.end.formatted(date: .omitted, time: .shortened)) · in \(Format.duration(w.end.timeIntervalSince(s.updated)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                // How far into the window we are.
                let elapsed = min(1, max(0, s.updated.timeIntervalSince(w.start) / TranscriptReader.windowLength))
                Capsule().fill(Color.secondary.opacity(0.2))
                    .overlay(alignment: .leading) {
                        GeometryReader { g in Capsule().fill(Self.accent).frame(width: g.size.width * elapsed) }
                    }
                    .frame(height: 6)
            } else {
                Text("No active window. One starts with your next message.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func week(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Last 7 days").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(Format.tokens(s.week.reduce(0) { $0 + $1.tokens })).font(.caption.weight(.medium)).monospacedDigit()
            }
            Chart(s.week, id: \.day) { day in
                BarMark(x: .value("Day", day.day, unit: .day), y: .value("Tokens", day.tokens))
                    .foregroundStyle(Self.accent)
                    .cornerRadius(3)
            }
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true) }
            }
            .frame(height: 70)
        }
    }

    private func models(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Today by model").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(s.todayByModel.prefix(5).enumerated()), id: \.offset) { i, entry in
                HStack {
                    Circle().fill(Self.palette[i % Self.palette.count]).frame(width: 8, height: 8)
                    Text(Format.model(entry.model))
                    Spacer()
                    Text(Format.tokens(entry.tokens)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let s = usage.snapshot {
                Text("All time \(Format.tokens(s.allTime)) · updated \(s.updated.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            // The same setting as the notch's: what sits beside the icon.
            Picker("Menu bar shows", selection: $shows) {
                ForEach(NotchShows.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .controlSize(.small)
            .font(.caption)
            HStack {
                Toggle("Animate icon", isOn: $animateIcon)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption)
                Toggle("Open at login", isOn: LoginItem.binding)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .glassButton()
                    .font(.caption)
            }
        }
    }
}

extension View {
    /// Liquid Glass on macOS 26 and later; a faint fill before that.
    @ViewBuilder func glassCard(cornerRadius: CGFloat = 12) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    @ViewBuilder func glassButton() -> some View {
        if #available(macOS 26, *) { buttonStyle(.glass) } else { buttonStyle(.borderless) }
    }
}
