import AppKit
import Combine
import SwiftUI

struct PopupPinch {
    let phase: NSEvent.Phase
    let scale: CGFloat
    let anchor: CGPoint
    let size: CGSize

    struct Tracker {
        private var anchor: CGPoint?
        private var size: CGSize = .zero
        private var scale: CGFloat = 1

        mutating func update(phase: NSEvent.Phase, delta: CGFloat, point: CGPoint, bounds: CGRect) -> PopupPinch? {
            if phase.contains(.began) { reset() }
            if anchor == nil {
                guard !phase.contains(.ended), !phase.contains(.cancelled), bounds.contains(point) else { return nil }
                anchor = point
                size = bounds.size
            }

            guard let anchor else { return nil }
            if delta.isFinite, !phase.contains(.cancelled) {
                scale = min(100, max(0.01, scale * max(0.1, 1 + delta)))
            }
            let pinch = PopupPinch(phase: phase, scale: scale, anchor: anchor, size: size)
            if phase.contains(.ended) || phase.contains(.cancelled) { reset() }
            return pinch
        }

        mutating func reset() {
            anchor = nil
            size = .zero
            scale = 1
        }
    }
}

struct IndirectPinch {
    struct ContactPair {
        let center: CGPoint
        let distance: CGFloat

        init(_ first: CGPoint, _ second: CGPoint) {
            center = CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
            distance = hypot(second.x - first.x, second.y - first.y)
        }
    }

    private var base: ContactPair?
    private var previousDistance: CGFloat?
    var isPinching: Bool { previousDistance != nil }

    mutating func update(_ contacts: ContactPair) -> (phase: NSEvent.Phase, delta: CGFloat)? {
        guard contacts.distance > 0.025 else { return nil }
        guard let base else {
            self.base = contacts
            return nil
        }
        if let previousDistance {
            self.previousDistance = contacts.distance
            return (.changed, contacts.distance / previousDistance - 1)
        }
        let separation = abs(contacts.distance - base.distance)
        let centerMovement = hypot(contacts.center.x - base.center.x, contacts.center.y - base.center.y)
        guard separation >= 0.022, separation > centerMovement * 1.25 else { return nil }
        previousDistance = contacts.distance
        return (.began, contacts.distance / base.distance - 1)
    }

    mutating func reset() {
        base = nil
        previousDistance = nil
    }
}

@MainActor
final class PopupInput {
    enum ScrollSurface { case calendar, globe }

    weak var panel: NSPanel?
    weak var viewport: NSView?
    weak var calendarViewport: NSView?
    let calendarPinches = PassthroughSubject<PopupPinch, Never>()
    let globePinches = PassthroughSubject<PopupPinch, Never>()

    private enum Source { case native, contacts }
    private var source: Source?
    private var tracker = PopupPinch.Tracker()
    private var indirect = IndirectPinch()
    private var active = true
    private var overGestureSurface = false
    private var pinchSurface: ScrollSurface?
    private var previousApp: NSRunningApplication?
    private var restoreTask: Task<Void, Never>?
    private var activationPending = false

    var isPinching: Bool { source != nil }

    func focusCalendarControls() {
        panel?.makeKey()
    }

    func scrollSurface(at point: NSPoint) -> ScrollSurface? {
        for (surface, view) in [(ScrollSurface.globe, viewport), (.calendar, calendarViewport)] {
            if let view, view.window === panel, view.bounds.contains(view.convert(point, from: nil)) {
                return surface
            }
        }
        return nil
    }

    func updatePointer(_ screenPoint: CGPoint) {
        guard active, let panel, panel.isVisible else {
            if overGestureSurface { leaveCanvas() }
            return
        }
        let hovered = scrollSurface(at: panel.convertPoint(fromScreen: screenPoint)) != nil
        guard hovered != overGestureSurface else { return }
        if hovered {
            overGestureSurface = true
            restoreTask?.cancel()
            if !NSApp.isActive, !activationPending {
                previousApp = NSWorkspace.shared.frontmostApplication
                requestActivation()
            }
            panel.makeKey()
        } else if overGestureSurface {
            leaveCanvas()
        }
    }

    func close() {
        active = false
        leaveCanvas()
    }

    private func requestActivation() {
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        guard !NSApp.isActive, Bundle.main.bundleURL.pathExtension == "app" else { return }

        // A hover can be rejected by cooperative activation. Launch Services can foreground the running instance.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        configuration.addsToRecentItems = false
        activationPending = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in
                self.activationPending = false
                if self.active, self.overGestureSurface {
                    self.panel?.makeKey()
                } else {
                    self.restorePreviousApp()
                }
            }
        }
    }

    private func leaveCanvas() {
        overGestureSurface = false
        if let surface = pinchSurface, let view = view(for: surface),
           let pinch = tracker.update(phase: .cancelled, delta: 0, point: .zero, bounds: view.bounds) {
            emit(pinch, to: surface)
        }
        pinchSurface = nil
        tracker.reset()
        indirect.reset()
        source = nil
        restorePreviousApp()
    }

    private func restorePreviousApp() {
        guard !activationPending, previousApp != nil else { return }
        restoreTask?.cancel()
        restoreTask = Task { @MainActor in
            // Let an outside click or an app switch settle before restoring the previous application.
            try? await Task.sleep(nanoseconds: 65_000_000)
            guard !Task.isCancelled, !overGestureSurface, let previousApp else { return }
            self.previousApp = nil
            if NSApp.isActive, !previousApp.isTerminated,
               previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                if #available(macOS 14, *) { NSApp.yieldActivation(to: previousApp) }
                previousApp.activate(options: [])
            }
        }
    }

    private func view(for surface: ScrollSurface) -> NSView? {
        let view = surface == .calendar ? calendarViewport : viewport
        return view?.window === panel ? view : nil
    }

    private func emit(_ pinch: PopupPinch, to surface: ScrollSurface) {
        switch surface {
        case .calendar: calendarPinches.send(pinch)
        case .globe: globePinches.send(pinch)
        }
    }

    func send(_ event: NSEvent) -> Bool {
        guard active, overGestureSurface, event.type == .magnify || event.type == .endGesture else { return false }
        if source == .contacts { return true }

        let phase = event.type == .endGesture ? NSEvent.Phase.ended : event.phase
        let delta = event.type == .magnify ? event.magnification : 0
        let hit = scrollSurface(at: event.locationInWindow)
        guard let surface = phase.contains(.began) ? hit : pinchSurface ?? hit,
              let view = view(for: surface) else { return false }

        let point = view.convert(event.locationInWindow, from: nil)
        guard let pinch = tracker.update(phase: phase, delta: delta, point: point, bounds: view.bounds)
        else { return false }

        let complete = phase.contains(.ended) || phase.contains(.cancelled)
        source = complete ? nil : .native
        pinchSurface = complete ? nil : surface
        indirect.reset()
        emit(pinch, to: surface)
        return true
    }

    func observeTouches(_ event: NSEvent, in view: NSView, ending: Bool = false, cancelled: Bool = false) -> Bool {
        guard active, overGestureSurface, let panel else { return false }
        let windowPoint = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        guard let surface = pinchSurface ?? scrollSurface(at: windowPoint),
              let target = self.view(for: surface) else { return false }

        let fingers = Array(event.touches(matching: .touching, in: view))
        let point = target.convert(windowPoint, from: nil)
        if source == .native {
            if ending, cancelled || fingers.count < 2 {
                let phase: NSEvent.Phase = cancelled ? .cancelled : .ended
                if let pinch = tracker.update(phase: phase, delta: 0, point: point, bounds: target.bounds) {
                    emit(pinch, to: surface)
                }
                source = nil
                pinchSurface = nil
                indirect.reset()
            }
            return false
        }
        guard !cancelled, fingers.count == 2 else {
            let wasPinching = source == .contacts
            if wasPinching {
                let phase: NSEvent.Phase = cancelled ? .cancelled : .ended
                if let pinch = tracker.update(phase: phase, delta: 0, point: point, bounds: target.bounds) {
                    emit(pinch, to: surface)
                }
                source = nil
                pinchSurface = nil
            }
            indirect.reset()
            return wasPinching
        }

        let device = fingers[0].deviceSize
        let aspect = device.width > 0 && device.height > 0 ? device.height / device.width : 0.65
        func position(_ touch: NSTouch) -> CGPoint {
            CGPoint(x: touch.normalizedPosition.x, y: touch.normalizedPosition.y * aspect)
        }
        let pair = IndirectPinch.ContactPair(position(fingers[0]), position(fingers[1]))
        guard let motion = indirect.update(pair),
              let pinch = tracker.update(phase: motion.phase, delta: motion.delta, point: point, bounds: target.bounds)
        else { return source == .contacts }

        source = .contacts
        pinchSurface = surface
        emit(pinch, to: surface)
        return true
    }
}

struct PopupSurface: NSViewRepresentable {
    let input: PopupInput
    let kind: PopupInput.ScrollSurface

    func makeNSView(context: Context) -> NSView {
        let view = Viewport()
        register(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        register(view)
    }

    private func register(_ view: NSView) {
        switch kind {
        case .calendar: input.calendarViewport = view
        case .globe: input.viewport = view
        }
    }

    private final class Viewport: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
