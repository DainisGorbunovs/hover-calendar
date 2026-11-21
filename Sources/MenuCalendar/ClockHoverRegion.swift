import AppKit

struct ClockHoverRegion {
    private let width: CGFloat
    private let rightInset: CGFloat

    init(defaults: UserDefaults = .standard) {
        let width = defaults.double(forKey: "ClockHoverWidth")
        let rightInset = defaults.object(forKey: "ClockHoverRightInset") as? Double ?? 20
        self.width = width.isFinite && width > 0 ? width : 145
        self.rightInset = rightInset.isFinite && rightInset >= 0 ? rightInset : 20
    }

    func frame(at point: CGPoint) -> CGRect? {
        let screens = NSScreen.screens
        guard let screen = screens.first(where: { $0.frame.contains(point) })
                ?? screens.first(where: { Self.contains(point, in: $0.frame) }),
              width + rightInset <= screen.frame.width else { return nil }

        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        guard menuBarHeight > 0 else { return nil }

        // Keep the bottom of the clock target and include the padding above it.
        let clockHeight = min(22, menuBarHeight)
        let height = (menuBarHeight + clockHeight) / 2
        let frame = CGRect(x: screen.frame.maxX - rightInset - width,
                           y: screen.frame.maxY - height,
                           width: width, height: height)
        return Self.contains(point, in: frame) ? frame : nil
    }

    static func contains(_ point: CGPoint, in frame: CGRect) -> Bool {
        // AppKit can report a pointer exactly at the display's top edge.
        point.x >= frame.minX && point.x < frame.maxX && point.y >= frame.minY && point.y <= frame.maxY
    }
}
