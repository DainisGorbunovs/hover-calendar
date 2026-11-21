import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let clockRegion = ClockHoverRegion()
    private let openDelay = 0.26
    private let closeDelay = 0.25

    private var panel: CalendarPanel?
    private var anchor: CGRect?
    private var candidate: (frame: CGRect, enteredAt: TimeInterval)?
    private var blockedAnchor: CGRect?
    private var leftAt: TimeInterval?
    private var menuIsOpen = false

    private var timer: Timer?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DaylightMapView.prepareGlobe()
        let timer = Timer(timeInterval: 0.09, target: self, selector: #selector(checkPointer),
                          userInfo: nil, repeats: true)
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            self?.pointerPressed()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks.union(.keyDown)) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53, let panel, event.window === panel {
                    dismissUntilPointerLeaves()
                    return nil
                }
            } else {
                pointerPressed()
            }
            return event
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    @objc private func checkPointer() {
        guard !menuIsOpen else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let point = NSEvent.mouseLocation
        if let anchor, let panel {
            if anchor.contains(point) || panel.frame.contains(point) {
                leftAt = nil
            } else if let leftAt {
                if now - leftAt >= closeDelay { dismiss() }
            } else {
                leftAt = now
            }
            return
        }

        if let blockedAnchor {
            if blockedAnchor.contains(point) { return }
            self.blockedAnchor = nil
        }
        guard NSEvent.pressedMouseButtons == 0, let frame = clockRegion.frame(at: point) else {
            candidate = nil
            return
        }
        guard let candidate, candidate.frame == frame else {
            candidate = (frame, now)
            return
        }
        if now - candidate.enteredAt >= openDelay {
            showCalendar(at: frame)
        }
    }

    private func pointerPressed() {
        guard !menuIsOpen else { return }
        let point = NSEvent.mouseLocation
        if panel?.frame.contains(point) == true { return }
        if let frame = clockRegion.frame(at: point) {
            blockedAnchor = frame
        }
        dismiss()
    }

    private func showCalendar(at frame: CGRect) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) })
        else { return }

        let panel = CalendarPanel(showOptions: { [weak self] in self?.showOptions() })
        let size = panel.frame.size
        let usable = screen.visibleFrame
        let x = min(max(frame.maxX - size.width, usable.minX + 8), usable.maxX - size.width - 8)
        let top = min(frame.minY - 7, usable.maxY - 5)
        panel.setFrameOrigin(CGPoint(x: x, y: top - size.height))

        self.panel = panel
        anchor = frame
        candidate = nil
        panel.orderFrontRegardless()
    }

    private func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        anchor = nil
        candidate = nil
        leftAt = nil
    }

    private func dismissUntilPointerLeaves() {
        blockedAnchor = anchor
        dismiss()
    }

    private func showOptions() {
        let menu = NSMenu()
        let quit = menu.addItem(withTitle: "Quit Menu Calendar", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q")
        quit.target = NSApp

        menuIsOpen = true
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        menuIsOpen = false
        leftAt = nil
    }
}
