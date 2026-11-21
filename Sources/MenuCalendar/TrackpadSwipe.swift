import AppKit

struct TrackpadSwipe {
    enum Direction {
        case left, right, up, down
    }

    private var travel: CGSize?
    private let minimumDistance: CGFloat = 32
    private let dominance: CGFloat = 1.35

    mutating func update(phase: NSEvent.Phase, deltaX: CGFloat, deltaY: CGFloat,
                         isInverted: Bool) -> Direction? {
        if phase.contains(.cancelled) {
            travel = nil
            return nil
        }
        if phase.contains(.began) {
            travel = .zero
        }
        guard var travel, !phase.intersection([.began, .changed, .ended]).isEmpty else { return nil }

        // Normalize to device direction so the same finger motion works with either scroll setting.
        let sign: CGFloat = isInverted ? -1 : 1
        travel.width += sign * deltaX
        travel.height += sign * deltaY
        guard phase.contains(.ended) else {
            self.travel = travel
            return nil
        }
        self.travel = nil

        let horizontal = abs(travel.width)
        let vertical = abs(travel.height)
        if horizontal >= minimumDistance, horizontal >= vertical * dominance {
            return travel.width > 0 ? .left : .right
        }
        if vertical >= minimumDistance, vertical >= horizontal * dominance {
            return travel.height > 0 ? .up : .down
        }
        return nil
    }
}
