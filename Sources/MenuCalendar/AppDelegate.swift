import AppKit
import CoreLocation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let clockRegion = ClockHoverRegion()
    private let location = LocalGlobeLocation()
    private let openDelay = 0.26
    private let closeDelay = 0.25

    private var panel: CalendarPanel?
    private var anchor: CGRect?
    private var candidate: (frame: CGRect, enteredAt: TimeInterval)?
    private var blockedAnchor: CGRect?
    private var leftAt: TimeInterval?
    private var menuIsOpen = false
    private var resetGlobeAction: (() -> Void)?
    private var globeLayerAction: ((GlobeLayer) -> Void)?

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
            panel.updatePointer(point)
            if ClockHoverRegion.contains(point, in: anchor) || panel.frame.contains(point) {
                leftAt = nil
            } else if let leftAt {
                if now - leftAt >= closeDelay { dismiss() }
            } else {
                leftAt = now
            }
            return
        }

        if let blockedAnchor {
            if ClockHoverRegion.contains(point, in: blockedAnchor) { return }
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

        location.refresh()
        let panel = CalendarPanel(location: location, showOptions: { [weak self] options in self?.showOptions(options) })
        let size = panel.frame.size
        let usable = screen.visibleFrame
        let x = min(max(frame.maxX - size.width, usable.minX + 8), usable.maxX - size.width - 8)
        let top = min(frame.minY - 7, usable.maxY - 5)
        panel.setFrameOrigin(CGPoint(x: x, y: top - size.height))

        self.panel = panel
        anchor = frame
        candidate = nil
        panel.reveal()
    }

    private func dismiss() {
        panel?.closePopup()
        panel = nil
        anchor = nil
        candidate = nil
        leftAt = nil
    }

    private func dismissUntilPointerLeaves() {
        blockedAnchor = anchor
        dismiss()
    }

    @objc private func resetGlobe() {
        resetGlobeAction?()
    }

    @objc private func useMyLocation() {
        switch location.authorization {
        case .denied, .restricted:
            let alert = NSAlert()
            alert.messageText = "Allow location access for Menu Calendar"
            alert.informativeText = "In System Settings, go to Privacy & Security → Location Services and allow Menu Calendar."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        case .notDetermined where !NSApp.isActive:
            resetGlobeAction?()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = false
            configuration.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { [weak self] _, error in
                guard error == nil else { return }
                Task { @MainActor in self?.location.requestAccess() }
            }
        default:
            resetGlobeAction?()
            location.requestAccess()
        }
    }

    @objc private func changeGlobeLayer(_ sender: NSMenuItem) {
        if let layer = GlobeLayer(rawValue: sender.tag) { globeLayerAction?(layer) }
    }

    private func showOptions(_ options: GlobeMenu) {
        let menu = NSMenu()
        resetGlobeAction = options.reset
        globeLayerAction = options.selectLayer
        defer {
            resetGlobeAction = nil
            globeLayerAction = nil
        }
        if options.selectLayer != nil {
            let layerMenu = NSMenu()
            for layer in GlobeLayer.allCases {
                let item = layerMenu.addItem(withTitle: layer.title, action: #selector(changeGlobeLayer(_:)), keyEquivalent: "")
                item.target = self
                item.tag = layer.rawValue
                item.state = layer == options.layer ? .on : .off
            }
            let layers = menu.addItem(withTitle: "Weather Layers", action: nil, keyEquivalent: "")
            layers.submenu = layerMenu
        }
        if options.reset != nil {
            let reset = menu.addItem(withTitle: "Reset Globe", action: #selector(Self.resetGlobe), keyEquivalent: "")
            reset.target = self
        }
        let locationTitle = location.updatesAllowed ? "Center on My Location" : "Use My Location…"
        let useLocation = menu.addItem(withTitle: locationTitle, action: #selector(Self.useMyLocation), keyEquivalent: "")
        useLocation.target = self
        menu.addItem(.separator())

        let quit = menu.addItem(withTitle: "Quit Menu Calendar", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q")
        quit.target = NSApp

        menuIsOpen = true
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        menuIsOpen = false
        leftAt = nil
    }
}
