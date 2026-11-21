import AppKit

struct TrackpadMotion {
    let phase: NSEvent.Phase
    let travel: CGSize
    let elapsed: TimeInterval

    var started: Bool { phase.contains(.began) }
    var cancelled: Bool { phase.contains(.cancelled) }
    var finished: Bool { phase.contains(.ended) }

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

            // Undo the scroll preference so positive deltas represent a physical swipe left or up.
            let sign: CGFloat = isInverted ? -1 : 1
            travel.width += sign * deltaX
            travel.height += sign * deltaY

            let motion = TrackpadMotion(phase: phase, travel: travel, elapsed: max(0, timestamp - beganAt))
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
