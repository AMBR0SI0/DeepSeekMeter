import SwiftUI
import Charts
import Pow

struct MinutePoint: Identifiable {
    let id: Int
    let date: Date
    let tokens: Int
}

struct RootView: View {
    let store: UsageStore
    let model: WidgetModel
    var onActivate: () -> Void

    @State private var openDay: String?
    @State private var reveal = false
    @State private var appeared = false

    private var level: Level { store.overallLevel }
    private var mode: WidgetState { model.mode }

    var body: some View {
        Group {
            switch mode {
            case .idle: idle
            case .hover: hover
            case .expanded: expanded
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: mode == .idle ? .center : .top)
        .modifier(GlassCard(radius: mode == .expanded ? 22 : (mode == .idle ? 15 : 16),
                            glow: level == .hot ? Palette.hot : nil))
        .opacity(appeared ? 1 : 0)
        .onAppear { withAnimation(.smooth(duration: 0.45)) { appeared = true } }
        .preferredColorScheme(.dark)
        .animation(.smooth(duration: 0.26), value: mode)
    }

    // MARK: Idle — a pill with one number and one quiet signal

    private var idle: some View {
        ZStack {
            HStack(spacing: 6) {
                Orb(level: level, size: 10, animated: false)

                Text(Fmt.money(store.balance.total, currency: store.balance.currency))
                    .number(12)
                    .foregroundStyle(Palette.accent)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                loadBar
                    .padding(.horizontal, 9)
                    .padding(.bottom, 4)
            }
        }
    }

    /// The busiest window's position between quiet and its red line, drawn as
    /// a hairline so the pill carries load without getting any wider.
    private var loadBar: some View {
        GeometryReader { geo in
            let load = max(
                fraction(store.tokens1m, store.thresholds.red1m),
                max(fraction(store.tokens10m, store.thresholds.red10m),
                    fraction(store.tokens1h, store.thresholds.red1h))
            )

            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(level.tint)
                    .frame(width: max(geo.size.width * min(load, 1), load > 0 ? 3 : 0))
            }
        }
        .frame(height: 2)
    }

    private func fraction(_ value: Int, _ red: Int) -> Double {
        guard red > 0 else { return 0 }
        return Double(value) / Double(red)
    }

    // MARK: Hover — windows, sparkline, request count

    private var hover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Orb(level: level, size: 12)

                Text("DeepSeek")
                    .number(10)
                    .lineLimit(1)

                Spacer(minLength: 3)

                Text(level.label)
                    .label(7)
                    .foregroundStyle(level.tint)
            }
            .padding(.top, 10)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Fmt.money(store.balance.total, currency: store.balance.currency))
                    .number(21)
                    .foregroundStyle(Palette.accent)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .changeEffect(.shine, value: store.balance.total)

                Text("left")
                    .label(7)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }
            .padding(.top, 4)

            VBars(values: store.sparkline.suffix(44).map { $0 }, tint: level.tint)
                .frame(height: 18)
                .padding(.top, 6)

            VStack(spacing: 6) {
                compactWindow("1 min", store.tokens1m, thresholds: (store.thresholds.warn1m, store.thresholds.red1m), level: store.level1m)
                compactWindow("10 min", store.tokens10m, thresholds: (store.thresholds.warn10m, store.thresholds.red10m), level: store.level10m)
                compactWindow("1 hour", store.tokens1h, thresholds: (store.thresholds.warn1h, store.thresholds.red1h), level: store.level1h)
            }
            .padding(.top, 8)

            Spacer(minLength: 2)

            HStack(spacing: 6) {
                Text("today")
                    .label(7)
                    .foregroundStyle(.secondary)
                Text(Fmt.compact(store.today.tokens))
                    .number(9)
                Text("·")
                    .foregroundStyle(.white.opacity(0.25))
                Text(Fmt.compact(store.today.requests) + " requests")
                    .number(9)
                    .foregroundStyle(.white.opacity(0.7))
                Spacer(minLength: 0)
            }
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 11)
    }

    private func compactWindow(
        _ title: String,
        _ value: Int,
        thresholds: (warn: Int, red: Int),
        level: Level
    ) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 5) {
                Text(title)
                    .label(8)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 2)

                Text(Fmt.compact(value))
                    .number(11)
                    .contentTransition(.numericText())

                Circle()
                    .fill(level.tint)
                    .frame(width: 4, height: 4)
            }

            GaugeBar(value: value, warn: thresholds.warn, red: thresholds.red, level: level, height: 3)
        }
    }

    // MARK: Expanded — the full report

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 0) {
            expandedHeader

            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    group(0.00) {
                        balanceHero
                        rule
                    }
                    group(0.04) { windows }
                    group(0.08) { minuteChart }
                    group(0.12) {
                        rule
                        report
                        footer
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
            .scrollIndicators(.never)
            .onAppear {
                guard !reveal else { return }
                withAnimation(.smooth(duration: 0.4)) { reveal = true }
            }
        }
        .onDisappear { reveal = false }
    }

    private var expandedHeader: some View {
        Button(action: onActivate) {
            HStack(spacing: 9) {
                Orb(level: level, size: 16, animated: false)

                VStack(alignment: .leading, spacing: 0) {
                    Text("DeepSeek").number(13)
                    Text("usage meter").label(7).foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 20, height: 20)
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func group<Content: View>(_ delay: Double, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 15, content: content)
            .opacity(reveal ? 1 : 0)
            .offset(y: reveal ? 0 : -7)
            .animation(.smooth(duration: 0.42).delay(delay), value: reveal)
    }

    private var rule: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 1)
    }

    private var balanceHero: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.money(store.balance.total, currency: store.balance.currency))
                    .number(28)
                    .foregroundStyle(Palette.accent)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Spacer()

                VStack(alignment: .trailing, spacing: 1) {
                    Text("remaining").label(8).foregroundStyle(.secondary)
                    Text(store.balance.currency.uppercased())
                        .label(8)
                        .foregroundStyle(.white.opacity(0.75))
                }
            }

            HStack(spacing: 14) {
                stat("tokens today", Fmt.compact(store.today.tokens))
                stat("requests", "\(store.today.requests)")
                stat("cache hit", Fmt.percent(store.today.cacheHitRate))
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).label(8).foregroundStyle(.secondary)
            Text(value).number(12).contentTransition(.numericText())
        }
    }

    private var windows: some View {
        VStack(spacing: 11) {
            windowRow("1 min", store.tokens1m, store.thresholds.warn1m, store.thresholds.red1m, store.level1m)
            windowRow("10 min", store.tokens10m, store.thresholds.warn10m, store.thresholds.red10m, store.level10m)
            windowRow("1 hour", store.tokens1h, store.thresholds.warn1h, store.thresholds.red1h, store.level1h)
        }
    }

    private func windowRow(_ title: String, _ value: Int, _ warn: Int, _ red: Int, _ level: Level) -> some View {
        VStack(spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .label(9)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)

                Text(Fmt.compact(value))
                    .number(13)
                    .contentTransition(.numericText())

                Spacer()

                Text(level.label)
                    .label(8)
                    .foregroundStyle(level.tint)
                    .opacity(level == .hot ? 1 : 0.7)
            }

            GaugeBar(value: value, warn: warn, red: red, level: level)
        }
    }

    private var chartPoints: [MinutePoint] {
        (0..<60).map { index in
            let bucket = store.bucket(at: index)
            return MinutePoint(id: index, date: bucket.date, tokens: bucket.tokens)
        }
    }

    private var minuteChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("last 60 minutes").label(8).foregroundStyle(.secondary)
                Spacer()
                Text("peak " + Fmt.compact(store.maxBucket))
                    .label(8)
                    .foregroundStyle(.white.opacity(0.45))
            }

            Chart(chartPoints) { point in
                AreaMark(
                    x: .value("Time", point.date),
                    y: .value("Tokens", point.tokens)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(LinearGradient(
                    colors: [level.tint.opacity(0.55), level.tint.opacity(0.02)],
                    startPoint: .top, endPoint: .bottom
                ))

                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Tokens", point.tokens)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(level.tint)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .minute, count: 20)) { _ in
                    AxisGridLine().foregroundStyle(.white.opacity(0.05))
                    AxisValueLabel(format: .dateTime.hour().minute(), centered: false)
                        .font(.system(size: 8))
                        .foregroundStyle(Color.white.opacity(0.35))
                }
            }
            .frame(height: 58)
            .animation(.smooth(duration: 0.6), value: store.tokens1m)
        }
    }

    private var report: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("daily report").label(8).foregroundStyle(.secondary)
                Spacer()
                Text("3 days · detail").label(8).foregroundStyle(.white.opacity(0.35))
            }

            ForEach(store.reportDays) { day in
                dayRow(day)
            }
        }
    }

    private func dayRow(_ day: DayRecord) -> some View {
        let fraction = Double(day.tokens) / Double(max(store.busiestDay, 1))
        let isOpen = openDay == day.key

        return Button {
            withAnimation(.smooth(duration: 0.3)) {
                openDay = isOpen ? nil : day.key
            }
        } label: {
            VStack(spacing: 7) {
                HStack(spacing: 9) {
                    Text(Fmt.weekday(day.key))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(isOpen ? .white : .white.opacity(0.72))
                        .frame(width: 58, alignment: .leading)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.05))
                            Capsule()
                                .fill(Palette.accent)
                                .frame(width: max(geo.size.width * CGFloat(fraction), day.tokens > 0 ? 5 : 0))
                        }
                    }
                    .frame(height: 5)

                    Text(Fmt.compact(day.tokens))
                        .number(11)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(width: 46, alignment: .trailing)
                        .foregroundStyle(.white.opacity(0.85))
                }

                if isOpen {
                    HStack(spacing: 12) {
                        chip("in", Fmt.compact(day.input))
                        chip("out", Fmt.compact(day.output))
                        chip("cached", Fmt.percent(day.cacheHitRate))
                        if day.spend > 0 {
                            chip("spend", Fmt.money(day.spend, currency: store.balance.currency))
                        }
                    }
                    .padding(.leading, 67)
                    .transition(.opacity.combined(with: .offset(y: -4)))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func chip(_ title: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(title).label(7).foregroundStyle(.secondary)
            Text(value).number(9).foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: store.problem == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 8))
                .foregroundStyle(store.problem == nil ? Palette.calm : Palette.warn)

            Text(store.problem ?? "updated " + Fmt.relative(store.lastScan))
                .font(.system(size: 8.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Text("click header to collapse")
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.22))
        }
    }
}
