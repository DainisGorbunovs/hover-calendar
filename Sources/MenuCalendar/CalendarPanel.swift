import AppKit
import Combine
import SwiftUI

final class CalendarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private let swipes = PassthroughSubject<TrackpadMotion, Never>()
    private var tracker = TrackpadMotion.Tracker()
    private let globePinch = GlobePinchInput()

    init(showOptions: @escaping () -> Void) {
        let view = CalendarView(showOptions: showOptions, swipes: swipes.eraseToAnyPublisher(), globePinch: globePinch)
        let hosting = CalendarHostingView(rootView: view)
        let bounds = CGRect(origin: .zero, size: hosting.fittingSize)
        super.init(contentRect: bounds, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)

        globePinch.panel = self
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

    func updateGlobePointer(_ point: CGPoint) {
        globePinch.updatePointer(point)
    }

    func closePopup() {
        globePinch.close()
        orderOut(nil)
    }

    override func sendEvent(_ event: NSEvent) {
        if globePinch.send(event) { return }
        guard event.type == .scrollWheel,
              event.hasPreciseScrollingDeltas,
              !event.phase.isEmpty || !event.momentumPhase.isEmpty else {
            super.sendEvent(event)
            return
        }

        if globePinch.isPinching { return }
        if !event.momentumPhase.isEmpty {
            swipes.send(.momentum(phase: event.momentumPhase, deltaX: event.scrollingDeltaX,
                                  deltaY: event.scrollingDeltaY, isInverted: event.isDirectionInvertedFromDevice))
        } else if let motion = tracker.update(phase: event.phase,
                                       deltaX: event.scrollingDeltaX,
                                       deltaY: event.scrollingDeltaY,
                                       isInverted: event.isDirectionInvertedFromDevice,
                                       timestamp: event.timestamp) {
            swipes.send(motion)
        }
    }
}

private final class CalendarHostingView: NSHostingView<CalendarView> {
    private let globePinch: GlobePinchInput

    required init(rootView: CalendarView) {
        globePinch = rootView.globePinch
        super.init(rootView: rootView)
        allowedTouchTypes = [.indirect]
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func touchesBegan(with event: NSEvent) {
        if !globePinch.observeTouches(event, in: self) { super.touchesBegan(with: event) }
    }

    override func touchesMoved(with event: NSEvent) {
        if !globePinch.observeTouches(event, in: self) { super.touchesMoved(with: event) }
    }

    override func touchesEnded(with event: NSEvent) {
        if !globePinch.observeTouches(event, in: self) { super.touchesEnded(with: event) }
    }

    override func touchesCancelled(with event: NSEvent) {
        if !globePinch.observeTouches(event, in: self, cancelled: true) { super.touchesCancelled(with: event) }
    }
}
