import AppKit
import Combine
import SwiftUI

final class CalendarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private let calendarSwipes = PassthroughSubject<TrackpadMotion, Never>()
    private let globeSwipes = PassthroughSubject<TrackpadMotion, Never>()
    private var scrollSurface: PopupInput.ScrollSurface?
    private var globeMomentum = false
    private var tracker = TrackpadMotion.Tracker()
    private let input = PopupInput()

    init(showOptions: @escaping () -> Void) {
        let view = CalendarView(showOptions: showOptions, calendarSwipes: calendarSwipes.eraseToAnyPublisher(),
                                globeSwipes: globeSwipes.eraseToAnyPublisher(), input: input)
        let hosting = CalendarHostingView(rootView: view)
        let bounds = CGRect(origin: .zero, size: hosting.fittingSize)
        super.init(contentRect: bounds, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)

        input.panel = self
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
        title = "Menu Calendar"
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    func reveal() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            orderFrontRegardless()
            return
        }
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.17
            animator().alphaValue = 1
        }
    }

    func updateGlobePointer(_ point: CGPoint) {
        input.updatePointer(point)
    }

    func closePopup() {
        input.close()
        orderOut(nil)
    }

    override func sendEvent(_ event: NSEvent) {
        if input.send(event) { return }
        if event.type == .keyDown,
           event.modifierFlags.contains(.command),
           event.modifierFlags.isDisjoint(with: [.shift, .option, .control]),
           event.charactersIgnoringModifiers?.lowercased() == "a",
           let editor = firstResponder as? NSTextView, editor.isFieldEditor {
            editor.selectAll(nil)
            return
        }
        guard event.type == .scrollWheel,
              event.hasPreciseScrollingDeltas,
              !event.phase.isEmpty || !event.momentumPhase.isEmpty else {
            super.sendEvent(event)
            return
        }

        if input.isPinching {
            globeMomentum = false
            return
        }
        if !event.momentumPhase.isEmpty {
            guard globeMomentum else { return }
            globeSwipes.send(.momentum(phase: event.momentumPhase, deltaX: event.scrollingDeltaX,
                                       deltaY: event.scrollingDeltaY, isInverted: event.isDirectionInvertedFromDevice))
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                globeMomentum = false
            }
            return
        }

        if event.phase.contains(.began) {
            scrollSurface = input.scrollSurface(at: event.locationInWindow)
            globeMomentum = false
        }
        guard let scrollSurface else {
            super.sendEvent(event)
            return
        }
        if let motion = tracker.update(phase: event.phase, deltaX: event.scrollingDeltaX,
                                       deltaY: event.scrollingDeltaY,
                                       isInverted: event.isDirectionInvertedFromDevice, timestamp: event.timestamp) {
            switch scrollSurface {
            case .calendar: calendarSwipes.send(motion)
            case .globe: globeSwipes.send(motion)
            }
            if motion.finished || motion.cancelled {
                globeMomentum = scrollSurface == .globe && motion.finished && !motion.cancelled
                self.scrollSurface = nil
            }
        }
    }
}

private final class CalendarHostingView: NSHostingView<CalendarView> {
    private let input: PopupInput

    required init(rootView: CalendarView) {
        input = rootView.input
        super.init(rootView: rootView)
        allowedTouchTypes = [.indirect]
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func touchesBegan(with event: NSEvent) {
        if !input.observeTouches(event, in: self) { super.touchesBegan(with: event) }
    }

    override func touchesMoved(with event: NSEvent) {
        if !input.observeTouches(event, in: self) { super.touchesMoved(with: event) }
    }

    override func touchesEnded(with event: NSEvent) {
        if !input.observeTouches(event, in: self) { super.touchesEnded(with: event) }
    }

    override func touchesCancelled(with event: NSEvent) {
        if !input.observeTouches(event, in: self, cancelled: true) { super.touchesCancelled(with: event) }
    }
}
