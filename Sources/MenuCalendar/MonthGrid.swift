import Foundation

struct MonthGrid {
    let start: Date
    let weeks: [[Date]]
    let weekdayNames: [String]
    let title: String

    init(containing date: Date, calendar: Calendar) {
        let start = calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
        self.start = start

        let weekday = calendar.component(.weekday, from: start)
        let precedingDays = (weekday - calendar.firstWeekday + 7) % 7
        weeks = (0..<6).map { week in
            (0..<7).compactMap { day in
                calendar.date(byAdding: .day, value: week * 7 + day - precedingDays, to: start)
            }
        }

        let formatter = DateFormatter()
        formatter.locale = calendar.locale ?? .autoupdatingCurrent
        formatter.calendar = calendar
        let symbols = formatter.shortStandaloneWeekdaySymbols ?? calendar.shortStandaloneWeekdaySymbols
        let firstIndex = calendar.firstWeekday - 1
        weekdayNames = Array(symbols[firstIndex...] + symbols[..<firstIndex])
        formatter.setLocalizedDateFormatFromTemplate("yMMMM")
        title = formatter.string(from: start)
    }
}
