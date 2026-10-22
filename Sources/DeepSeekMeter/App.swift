import AppKit
import Observation
import QuartzCore
import SwiftUI

@main
struct DeepSeekMeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("DeepSeek Meter", systemImage: "gauge.with.dots.needle.67percent") {
            Button("Show Meter") { PanelController.shared.show() }
            Button("Refresh Now") {
                UsageStore.shared.scan()
                Task { await UsageStore.shared.refreshBalance() }
            }
            Divider()
            Button("Quit DeepSeek Meter") { NSApp.terminate(nil) }
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

/// Shared presentation state; the controller writes it, SwiftUI reads it.
@MainActor
@Observable
final class WidgetModel {
    var mode: WidgetState = .idle
}

/// Renders each state through a live window, which is the only way ScrollView,
/// materials and the hover layout lay out offscreen.
@MainActor
enum Snapshot {
    static func render() {
        render(.idle)
        render(.hover)
        render(.expanded)
    }

    private static func render(_ mode: WidgetState) {
        let model = WidgetModel()
        model.mode = mode
        let host = NSHostingView(rootView: RootView(store: .shared, model: model) {})

        capture(host, size: PanelController.Layout.size(mode), path: "/tmp/deepseekmeter-\(mode).png")
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

final class WidgetPanel: NSPanel {
    var onTap: (() -> Void)?
    var onDragEnd: (() -> Void)?
    /// Off while the full report is open so SwiftUI gets every click.
    var handlesPointer = true

    private var downPoint: NSPoint?
    private var dragging = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        guard handlesPointer else {
            super.sendEvent(event)
            return
        }

        switch event.type {
        case .leftMouseDown:
            downPoint = event.locationInWindow
            dragging = false

        case .leftMouseDragged:
            if let start = downPoint, !dragging {
                let point = event.locationInWindow
                if hypot(point.x - start.x, point.y - start.y) > 3 {
                    dragging = true
                    performDrag(with: event)
                    downPoint = nil
                    dragging = false
                    onDragEnd?()
                    return
                }
            }

        case .leftMouseUp:
            if !dragging, downPoint != nil { onTap?() }
            downPoint = nil

        default:
            break
        }

        super.sendEvent(event)
    }
}

final class HoverHostingView<Content: View>: NSHostingView<Content> {
    var onHoverChange: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?
    private var inside = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard !inside else { return }
        inside = true
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard inside else { return }
        // Rebuilding the tracking area on resize can fake an exit while the
        // pointer is still over the panel.
        let point = convert(event.locationInWindow, from: nil)
        guard !bounds.contains(point) else { return }
        inside = false
        onHoverChange?(false)
    }
}

@MainActor
final class PanelController: NSObject {
    static let shared = PanelController()

    enum Layout {
        static let gap: CGFloat = 12
        /// A horizontal pill, the whole widget at rest.
        static let idle = CGSize(width: 116, height: 30)
        static let hover = CGSize(width: 200, height: 192)
        static let expanded = CGSize(width: 292, height: 500)

        static func size(_ mode: WidgetState) -> CGSize {
            switch mode {
            case .idle: return idle
            case .hover: return hover
            case .expanded: return expanded
            }
        }
    }

    let model = WidgetModel()
    private var panel: WidgetPanel?
    private var pointerInside = false
    private var hoverTask: Task<Void, Never>?
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

        panel.onTap = { [weak self] in self?.activate() }
        panel.onDragEnd = { [weak self] in self?.reanchor() }

        let host = HoverHostingView(rootView: RootView(store: .shared, model: model) { [weak self] in
            self?.activate()
        })
        host.onHoverChange = { [weak self] inside in self?.hover(inside) }
        panel.contentView = host

        panel.setFrame(
            NSRect(origin: defaultOrigin(), size: Layout.idle).clampedToScreen(),
            display: false
        )
        panel.orderFrontRegardless()
        self.panel = panel
        startWatchdog()
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

    private func activate() {
        switch model.mode {
        case .expanded: setMode(pointerInside ? .hover : .idle)
        case .idle, .hover: setMode(.expanded)
        }
    }

    private func hover(_ inside: Bool) {
        pointerInside = inside
        hoverTask?.cancel()
        guard model.mode != .expanded else { return }

        guard inside else {
            setMode(.idle)
            return
        }

        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            self?.setMode(.hover)
        }
    }

    private func setMode(_ next: WidgetState) {
        guard model.mode != next else { return }
        model.mode = next

        guard let panel else { return }
        panel.handlesPointer = next != .expanded

        let target = targetFrame(for: next, from: panel.frame)
        let duration: TimeInterval = next == .expanded ? 0.34 : 0.22

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            panel.animator().setFrame(target, display: true)
        }
    }

    // MARK: Geometry

    private func reanchor() {
        guard let panel else { return }
        let target = targetFrame(for: model.mode, from: panel.frame)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            panel.animator().setFrame(target, display: true)
        }
    }

    /// Pins the nearest horizontal edge, and grows away from the nearest
    /// vertical one so the corner the user can see never moves.
    private func targetFrame(for mode: WidgetState, from current: NSRect) -> NSRect {
        guard let visible = PanelController.screen(for: current)?.visibleFrame else { return current }

        let size = Layout.size(mode)
        let side: CGFloat = current.midX < visible.midX ? 1 : -1

        var frame = NSRect(origin: current.origin, size: size)
        frame.origin.x = side > 0
            ? visible.minX + Layout.gap
            : visible.maxX - size.width - Layout.gap
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
