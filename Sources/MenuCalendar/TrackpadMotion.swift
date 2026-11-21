import AppKit

struct TrackpadMotion {
    let phase: NSEvent.Phase
    let travel: CGSize
    let elapsed: TimeInterval
    let isMomentum: Bool

    var started: Bool { phase.contains(.began) }
    var cancelled: Bool { phase.contains(.cancelled) }
    var finished: Bool { phase.contains(.ended) }

    static func momentum(phase: NSEvent.Phase, deltaX: CGFloat, deltaY: CGFloat, isInverted: Bool) -> Self {
        Self(phase: phase, travel: deviceTravel(deltaX, deltaY, isInverted: isInverted), elapsed: 0, isMomentum: true)
    }

    private static func deviceTravel(_ x: CGFloat, _ y: CGFloat, isInverted: Bool) -> CGSize {
        // Positive deltas follow a physical swipe left or up under either scroll preference.
        let sign: CGFloat = isInverted ? -1 : 1
        return CGSize(width: sign * x, height: sign * y)
    }

    struct Tracker {
        private var travel: CGSize = .zero
        private var beganAt: TimeInterval?

        mutating func update(phase: NSEvent.Phase, deltaX: CGFloat, deltaY: CGFloat,
                             isInverted: Bool, timestamp: TimeInterval) -> TrackpadMotion? {
            if phase.contains(.began) {
                beganAt = timestamp
                travel = .zero
            }
            guard let beganAt,
                  !phase.intersection([.began, .changed, .ended, .cancelled]).isEmpty else { return nil }

            let change = TrackpadMotion.deviceTravel(deltaX, deltaY, isInverted: isInverted)
            travel.width += change.width
            travel.height += change.height

            let motion = TrackpadMotion(phase: phase, travel: travel,
                                        elapsed: max(0, timestamp - beganAt), isMomentum: false)
            if motion.finished || motion.cancelled {
                self.beganAt = nil
            }
            return motion
        }
    }
}

struct MonthSwipe {
    private enum Axis {
        case undecided, horizontal, vertical
    }

    private var axis = Axis.undecided

    mutating func preview(_ motion: TrackpadMotion, width: CGFloat) -> Double {
        if motion.started { axis = .undecided }
        let horizontal = abs(motion.travel.width)
        let vertical = abs(motion.travel.height)
        if axis == .undecided {
            if horizontal >= 10, horizontal >= vertical * 1.25 {
                axis = .horizontal
            } else if vertical >= 10, vertical >= horizontal * 1.25 {
                axis = .vertical
            }
        }
        guard axis == .horizontal else { return 0 }
        return min(0.95, max(-0.95, motion.travel.width / width))
    }

    func monthChange(for motion: TrackpadMotion) -> Int {
        guard axis == .horizontal, !motion.cancelled else { return 0 }
        let threshold: CGFloat = motion.elapsed <= 0.24 ? 32 : 69
        guard abs(motion.travel.width) >= threshold else { return 0 }
        return motion.travel.width > 0 ? 1 : -1
    }
}
