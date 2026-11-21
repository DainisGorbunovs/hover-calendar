import Foundation

struct CalendarYear {
    let months: [Date]

    init?(containing date: Date, calendar: Calendar) {
        guard let year = calendar.dateInterval(of: .year, for: date) else { return nil }
        var months: [Date] = []
        var cursor = year.start
        while cursor < year.end {
            months.append(cursor)
            guard let month = calendar.dateInterval(of: .month, for: cursor), month.end > cursor else { return nil }
            cursor = month.end
        }
        self.months = months
    }

    static func date(forYear text: String, near reference: Date, calendar: Calendar) -> Date? {
        let characters = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = characters.compactMap(\.wholeNumberValue)
        guard !digits.isEmpty, digits.count == characters.count, digits.count <= 4,
              digits.allSatisfy({ (0...9).contains($0) }) else { return nil }

        let year = digits.reduce(0) { $0 * 10 + $1 }
        let referenceYear = calendar.component(.year, from: reference)
        guard year > 0,
              let date = calendar.date(byAdding: .year, value: year - referenceYear, to: reference),
              calendar.component(.year, from: date) == year,
              calendar.component(.era, from: date) == calendar.component(.era, from: reference)
        else { return nil }
        return date
    }
}
