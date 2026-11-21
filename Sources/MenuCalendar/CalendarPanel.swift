import AppKit
import Combine
import SwiftUI

final class CalendarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private let swipes = PassthroughSubject<TrackpadSwipe.Direction, Never>()
    private var swipe = TrackpadSwipe()

    init(showOptions: @escaping () -> Void) {
        let view = CalendarView(showOptions: showOptions, swipes: swipes.eraseToAnyPublisher())
        let hosting = NSHostingView(rootView: view)
        let bounds = CGRect(origin: .zero, size: hosting.fittingSize)
        super.init(contentRect: bounds, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)

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

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .scrollWheel,
              event.hasPreciseScrollingDeltas,
              !event.phase.isEmpty,
              event.momentumPhase.isEmpty else {
            super.sendEvent(event)
            return
        }

        if let direction = swipe.update(phase: event.phase,
                                        deltaX: event.scrollingDeltaX,
                                        deltaY: event.scrollingDeltaY,
                                        isInverted: event.isDirectionInvertedFromDevice) {
            swipes.send(direction)
        }
    }
}
