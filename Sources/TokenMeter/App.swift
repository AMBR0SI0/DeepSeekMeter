import AppKit
import Observation
import QuartzCore
import SwiftUI

@main
struct TokenMeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Token Meter", systemImage: "gauge.with.dots.needle.67percent") {
            Button("Show Meter") { PanelController.shared.show() }
            Button("Expand Meter") { PanelController.shared.expand() }
            Button("Reset Position") { PanelController.shared.resetPosition() }
            Divider()
            Button("Edit Configuration…") { Configuration.open() }
            Button("Reload Configuration") { UsageStore.shared.reloadConfiguration() }
            Button("Open Data Folder") {
                NSWorkspace.shared.activateFileViewerSelecting([UsageStore.dataDirectory])
            }
            Button("Refresh Now") {
                UsageStore.shared.scan()
                Task { await UsageStore.shared.refreshBalance() }
            }
            Divider()
            Button("Quit Token Meter") { NSApp.terminate(nil) }
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UsageStore.shared.start()

        if CommandLine.arguments.contains("--snapshot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                Snapshot.render()
                NSApp.terminate(nil)
            }
            return
        }
        PanelController.shared.show()
    }
}

/// The config file is a plain JSON document next to the state file. When it
/// does not exist, a template for the detected provider is written first so
/// "Edit Configuration…" always opens something useful.
enum Configuration {
    static func open() {
        let url = UsageStore.configFileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? template.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }

    private struct Template: Encodable {
        var provider: Provider
        var pricing: Pricing
        var historyDays: Int
    }

    private static var template: String {
        let preset = Presets.detect()
        let template = Template(provider: preset.provider, pricing: preset.pricing, historyDays: 7)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(template),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text + "\n"
    }
}

/// Shared presentation state; the controller writes it, SwiftUI reads it.
@MainActor
@Observable
final class WidgetModel {
    var mode: WidgetState = .idle
}

/// Renders each state through a live window, which is the only way ScrollView,
/// materials and the compact layout lay out offscreen.
@MainActor
enum Snapshot {
    static func render() {
        render(.idle)
        render(.compact)
        render(.expanded)
    }

    /// Screenshots ship with the repository, so they use generated figures
    /// rather than whatever happened to be in the author's account.
    private static func demoStore() -> UsageStore {
        let store = UsageStore()
        let fixed = Date()
        store.now = { fixed }

        var seed: UInt64 = 0x5EED
        func random() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((seed >> 33) % 1_000) / 1_000
        }

        var minutes: [String: Int] = [:]
        for index in 0..<60 {
            let date = Calendar.current.date(byAdding: .minute, value: index - 59, to: fixed) ?? fixed
            let wave = sin(Double(index) / 6.5) * 0.5 + 0.5
            // Two quiet stretches so the chart reads like real work, not a sine wave.
            let idle = (20...26).contains(index) || (44...46).contains(index)
            let tokens = idle ? 0 : Int(wave * 320_000 + random() * 120_000)
            minutes[Clock.minuteKey(date)] = tokens
        }
        store.minutes = minutes

        func day(_ offset: Int, _ tokens: Int, _ requests: Int) -> (String, DayRecord) {
            let date = Calendar.current.date(byAdding: .day, value: offset, to: fixed) ?? fixed
            var record = DayRecord(key: Clock.dayKey(date))
            record.tokens = tokens
            record.requests = requests
            record.input = Int(Double(tokens) * 0.16)
            record.output = Int(Double(tokens) * 0.03)
            record.cacheRead = Int(Double(tokens) * 0.81)
            // A blended rate keeps the demo honest-looking without pretending
            // one model priced the whole day.
            record.spend = Double(tokens) / 1_000_000 * 0.26
            record.pricedTokens = tokens
            return (record.key, record)
        }

        store.days = Dictionary(uniqueKeysWithValues: [
            day(0, 13_240_000, 968),
            day(-1, 38_640_000, 1_940),
            day(-2, 22_150_000, 1_204),
            day(-3, 9_800_000, 612),
            day(-4, 31_050_000, 1_502),
            day(-5, 4_420_000, 318),
            day(-6, 0, 0),
        ])
        store.balance = Balance(total: 42.80, granted: 10, toppedUp: 32.80, currency: "USD", fetchedAt: fixed)
        store.lastScan = fixed
        store.isReady = true
        return store
    }

    private static func render(_ mode: WidgetState) {
        let model = WidgetModel()
        model.mode = mode
        let host = NSHostingView(rootView: RootView(store: demoStore(), model: model))

        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "docs/screenshots", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        capture(
            host,
            size: PanelController.Layout.size(mode),
            path: dir.appending(path: "\(mode).png").path
        )
    }

    private static func capture<V: View>(_ host: NSHostingView<V>, size: CGSize, path: String) {
        host.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.09, green: 0.10, blue: 0.13, alpha: 1)
        window.isOpaque = true
        window.contentView = host
        window.orderFront(nil)

        RunLoop.current.run(until: Date().addingTimeInterval(0.9))
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        window.orderOut(nil)
    }
}

/// The hosting view takes the first click even when another app is active;
/// without that, the click that wakes the HUD is swallowed by activation.
final class HUDHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class WidgetPanel: NSPanel {
    /// Called on a click that never turned into a drag, with the point in
    /// window coordinates so the controller can ignore its own buttons.
    var onTap: ((NSPoint) -> Void)?
    var onDragEnd: (() -> Void)?

    private var downEvent: NSEvent?
    /// `performDrag` returns before the window has moved, so the drag only
    /// counts as finished when its mouse-up arrives.
    private var dragging = false

    /// A HUD that never takes keyboard focus from the app you are actually typing in.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            downEvent = event
            dragging = false

        case .leftMouseDragged:
            guard let start = downEvent else { break }
            let from = start.locationInWindow
            let to = event.locationInWindow
            guard hypot(to.x - from.x, to.y - from.y) > 3 else { break }

            dragging = true
            downEvent = nil
            // Anchor the move to the mouse-down event. Anchoring to the first
            // dragged event offsets the window by the drag threshold every
            // time, which is what made it jump.
            performDrag(with: start)
            return

        case .leftMouseUp:
            if dragging {
                dragging = false
                onDragEnd?()
            } else if downEvent != nil {
                onTap?(event.locationInWindow)
            }
            downEvent = nil

        default:
            break
        }

        super.sendEvent(event)
    }
}

@MainActor
final class PanelController: NSObject {
    static let shared = PanelController()

    enum Layout {
        static let gap: CGFloat = 12
        /// A horizontal pill, the whole widget at rest.
        static let idle = CGSize(width: 116, height: 30)
        static let compact = CGSize(width: 200, height: 192)
        static let expanded = CGSize(width: 292, height: 500)
        /// Top-right corner of the compact card holding its two buttons. A
        /// click there is a button press, not a click on the card itself.
        static let compactControls = 44.0

        static func size(_ mode: WidgetState) -> CGSize {
            switch mode {
            case .idle: return idle
            case .compact: return compact
            case .expanded: return expanded
            }
        }
    }

    let model = WidgetModel()
    private var panel: WidgetPanel?
    private var watchdog: Timer?

    private override init() {
        super.init()
        // A display that goes away leaves the panel parked at an off-screen
        // origin, so it has to be pulled back whenever the geometry changes.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(environmentDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(environmentDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    // MARK: Presentation

    func show() {
        if let panel {
            ensureOnScreen()
            panel.orderFrontRegardless()
            return
        }

        let panel = WidgetPanel(
            contentRect: NSRect(origin: .zero, size: Layout.idle),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.isMovableByWindowBackground = false

        panel.onTap = { [weak self] point in self?.tapped(at: point) }
        panel.onDragEnd = { [weak self] in self?.reanchor() }

        panel.contentView = HUDHostingView(
            rootView: RootView(
                store: .shared,
                model: model,
                onExpand: { [weak self] in self?.setMode(.expanded) },
                onCollapse: { [weak self] in self?.setMode(.compact) },
                onMinimize: { [weak self] in self?.setMode(.idle) }
            )
        )

        panel.setFrame(
            NSRect(origin: defaultOrigin(), size: Layout.idle).clampedToScreen(),
            display: false
        )
        panel.orderFrontRegardless()
        self.panel = panel
        startWatchdog()
    }

    /// Opens the full report, for the menu bar fallback.
    func expand() {
        show()
        setMode(.expanded)
    }

    /// Puts the pill back in the top-right corner, collapsed.
    func resetPosition() {
        guard let panel else {
            show()
            return
        }
        model.mode = .idle

        let target = NSRect(origin: defaultOrigin(), size: Layout.idle).clampedToScreen()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            panel.animator().setFrame(target, display: true)
        }
    }

    // MARK: Staying on screen

    /// The panel is a HUD: whatever happens to displays or spaces, it belongs
    /// fully inside one screen's visible frame and above the other windows.
    @objc private func environmentDidChange() {
        guard let panel else { return }
        ensureOnScreen()
        panel.orderFrontRegardless()
    }

    @objc private func watchdogTick() {
        guard let panel else { return }
        ensureOnScreen()
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = Timer(timeInterval: 3, target: self, selector: #selector(watchdogTick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func ensureOnScreen() {
        guard let panel else { return }
        let target = panel.frame.clampedToScreen()
        if target != panel.frame {
            panel.setFrame(target, display: true)
        }
    }

    /// The screen holding most of the panel, falling back to the main display
    /// when the panel is on a display that no longer exists.
    fileprivate nonisolated static func screen(for frame: NSRect) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        var best: (screen: NSScreen, area: CGFloat)?
        for screen in screens {
            let clipped = screen.visibleFrame.intersection(frame)
            let area = clipped.isEmpty ? 0 : clipped.width * clipped.height
            if area > (best?.area ?? 0) { best = (screen, area) }
        }
        return best?.screen ?? NSScreen.main ?? screens.first
    }

    // MARK: State

    /// A click that stayed still. Clicks on the compact card's buttons never
    /// reach here because they sit inside `compactControls`.
    private func tapped(at point: NSPoint) {
        switch model.mode {
        case .idle:
            setMode(.compact)

        case .compact:
            let size = Layout.size(.compact)
            let onControls = point.x > size.width - Layout.compactControls
                && point.y > size.height - 26
            if !onControls { setMode(.expanded) }

        case .expanded:
            break
        }
    }

    private func setMode(_ next: WidgetState) {
        guard model.mode != next else { return }
        model.mode = next

        guard let panel else { return }

        let target = targetFrame(for: next, from: panel.frame)
        let duration: TimeInterval = next == .expanded ? 0.34 : 0.22

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            panel.animator().setFrame(target, display: true)
        }
    }

    // MARK: Geometry

    /// A drag left the panel where the user dropped it. Only when it is
    /// dropped close to a side does it settle against that edge — snapping
    /// from the middle of the screen would undo the drag.
    private func reanchor() {
        guard let panel,
              let visible = PanelController.screen(for: panel.frame)?.visibleFrame else { return }

        let threshold: CGFloat = 48
        var target = panel.frame
        if panel.frame.minX - visible.minX < threshold {
            target.origin.x = visible.minX + Layout.gap
        } else if visible.maxX - panel.frame.maxX < threshold {
            target.origin.x = visible.maxX - panel.frame.width - Layout.gap
        }
        target = target.clampedToScreen()
        guard target != panel.frame else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            panel.animator().setFrame(target, display: true)
        }
    }

    /// Keeps the horizontal position and grows away from the nearest vertical
    /// edge, so the corner the user is looking at never moves. Clamping pulls
    /// the panel back on screen when it grows toward a side.
    private func targetFrame(for mode: WidgetState, from current: NSRect) -> NSRect {
        guard let visible = PanelController.screen(for: current)?.visibleFrame else { return current }

        let size = Layout.size(mode)
        var frame = NSRect(origin: current.origin, size: size)
        frame.origin.y = current.midY >= visible.midY
            ? current.maxY - size.height
            : current.minY
        return frame.clampedToScreen()
    }

    private func defaultOrigin() -> CGPoint {
        guard let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else {
            return CGPoint(x: 80, y: 80)
        }
        return CGPoint(
            x: visible.maxX - Layout.idle.width - Layout.gap,
            y: visible.maxY - Layout.idle.height - Layout.gap
        )
    }
}

extension NSRect {
    /// Slides a rect into whichever screen holds most of it, leaving a small
    /// margin so the shadow and rounded corners never sit on the edge.
    func clampedToScreen() -> NSRect {
        guard let visible = PanelController.screen(for: self)?.visibleFrame else { return self }
        let inset: CGFloat = 6
        var frame = self
        frame.origin.x = min(max(frame.minX, visible.minX + inset), visible.maxX - frame.width - inset)
        frame.origin.y = min(max(frame.minY, visible.minY + inset), visible.maxY - frame.height - inset)
        return frame
    }
}
