import SwiftUI

struct CalendarPalette {
    let surface: Color
    let outline: Color
    let track: Color
    let activeTab: Color
    let text: Color
    let secondary: Color
    let adjacent: Color
    let weekendSurface: Color
    let weekendText: Color
    let accent: Color
    let holiday: Color

    static let dark = CalendarPalette(
        surface: Color(rgb: 0x1C1D23),
        outline: Color(rgb: 0x34353E),
        track: Color(rgb: 0x25262D),
        activeTab: Color(rgb: 0x393A45),
        text: Color(rgb: 0xF3F0F6),
        secondary: Color(rgb: 0xB4B0BE),
        adjacent: Color(rgb: 0x928E9F),
        weekendSurface: Color(rgb: 0x30262C),
        weekendText: Color(rgb: 0xEDB5A2),
        accent: Color(rgb: 0x7152CE),
        holiday: Color(rgb: 0x80D5C2)
    )

    static let light = CalendarPalette(
        surface: Color(rgb: 0xFCFAF6),
        outline: Color(rgb: 0xE3DDD7),
        track: Color(rgb: 0xF0EDE8),
        activeTab: .white,
        text: Color(rgb: 0x272530),
        secondary: Color(rgb: 0x615B6A),
        adjacent: Color(rgb: 0x6D6774),
        weekendSurface: Color(rgb: 0xF7EAE4),
        weekendText: Color(rgb: 0x94493C),
        accent: Color(rgb: 0x6847C7),
        holiday: Color(rgb: 0x136B5C)
    )
}

private extension Color {
    init(rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 0xff) / 255,
                  green: Double((rgb >> 8) & 0xff) / 255,
                  blue: Double(rgb & 0xff) / 255)
    }
}
