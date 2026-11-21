import Foundation

struct WorldClockLocation: Identifiable {
    let name: String
    let timeZone: TimeZone
    var id: String { timeZone.identifier }

    static let locations = [
        ("London", "Europe/London"),
        ("New York", "America/New_York"),
        ("Chicago", "America/Chicago"),
        ("San Francisco", "America/Los_Angeles"),
        ("Riga", "Europe/Riga"),
        ("Taipei", "Asia/Taipei")
    ].compactMap { name, identifier in
        TimeZone(identifier: identifier).map { WorldClockLocation(name: name, timeZone: $0) }
    }

    struct Reading {
        let time: String
        let zone: String
        let differentDay: String?
    }

    func reading(at date: Date, relativeTo localTimeZone: TimeZone = .autoupdatingCurrent) -> Reading {
        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.timeZone = localTimeZone
        var cityCalendar = localCalendar
        cityCalendar.timeZone = timeZone

        let clockFormat = Date.VerbatimFormatStyle(
            format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            locale: .autoupdatingCurrent, timeZone: timeZone, calendar: cityCalendar
        )
        let dateComponents: Set<Calendar.Component> = [.year, .month, .day]
        let sameDay = localCalendar.dateComponents(dateComponents, from: date)
            == cityCalendar.dateComponents(dateComponents, from: date)
        let dayFormat = Date.FormatStyle(calendar: cityCalendar, timeZone: timeZone).weekday(.abbreviated).day()

        let offset = timeZone.secondsFromGMT(for: date)
        let magnitude = abs(offset) / 60
        let minutes = magnitude % 60
        let minutePart = minutes == 0 ? "" : String(format: ":%02d", minutes)
        let utcOffset = "UTC\(offset < 0 ? "−" : "+")\(magnitude / 60)\(minutePart)"
        let abbreviation = abbreviation(at: date, offset: offset)

        return Reading(time: date.formatted(clockFormat),
                       zone: abbreviation.map { "\($0) · \(utcOffset)" } ?? utcOffset,
                       differentDay: sameDay ? nil : date.formatted(dayFormat))
    }

    private func abbreviation(at date: Date, offset: Int) -> String? {
        let style: TimeZone.NameStyle = timeZone.isDaylightSavingTime(for: date) ? .shortDaylightSaving : .shortStandard
        let candidates = [
            timeZone.abbreviation(for: date),
            timeZone.localizedName(for: style, locale: Locale(identifier: "en_GB"))
        ]
        return candidates.compactMap { $0 }.first { !$0.isEmpty && $0.allSatisfy(\.isLetter) }
            ?? (offset == 0 ? "GMT" : nil)
    }
}
