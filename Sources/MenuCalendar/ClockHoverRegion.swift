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
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              width + rightInset <= screen.frame.width else { return nil }

        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        guard menuBarHeight > 0, point.y >= screen.visibleFrame.maxY else { return nil }

        // The system reports the menu bar's bounds. Fit the region to the clock layout in points.
        let height = min(22, menuBarHeight)
        let frame = CGRect(x: screen.frame.maxX - rightInset - width,
                           y: screen.frame.maxY - (menuBarHeight + height) / 2,
                           width: width, height: height)
        return frame.contains(point) ? frame : nil
    }
}
