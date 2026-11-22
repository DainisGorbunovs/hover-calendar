import Foundation

struct WorldClockLocation: Identifiable, Equatable {
    let name: String
    let timeZone: TimeZone
    let flag: String
    let latitude: Double
    let longitude: Double
    let id: String

    init(name: String, timeZone: TimeZone, flag: String, latitude: Double, longitude: Double, id: String? = nil) {
        self.name = name
        self.timeZone = timeZone
        self.flag = flag
        self.latitude = latitude
        self.longitude = longitude
        self.id = id ?? timeZone.identifier
    }

    static let locations = [
        ("London", "Europe/London", "🇬🇧", 51.5074, -0.1278),
        ("New York", "America/New_York", "🇺🇸", 40.7128, -74.0060),
        ("Chicago", "America/Chicago", "🇺🇸", 41.8781, -87.6298),
        ("San Francisco", "America/Los_Angeles", "🇺🇸", 37.7749, -122.4194),
        ("Riga", "Europe/Riga", "🇱🇻", 56.9496, 24.1052),
        ("Taipei", "Asia/Taipei", "🇹🇼", 25.0330, 121.5654)
    ].compactMap { name, identifier, flag, latitude, longitude in
        TimeZone(identifier: identifier).map {
            WorldClockLocation(name: name, timeZone: $0, flag: flag, latitude: latitude, longitude: longitude)
        }
    }

    static var localOrDefault: Self? {
        locations.first { $0.id == TimeZone.autoupdatingCurrent.identifier } ?? locations.first
    }

    static func orderedByLocalTime(at instant: Date) -> [Self] {
        // For one instant, adding the UTC offset gives local civil date and time, including the day rollover.
        locations.sorted { lhs, rhs in
            let left = lhs.timeZone.secondsFromGMT(for: instant)
            let right = rhs.timeZone.secondsFromGMT(for: instant)
            return left == right ? lhs.name < rhs.name : left < right
        }
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

        return Reading(time: localTime(at: date),
                       zone: abbreviation.map { "\($0) · \(utcOffset)" } ?? utcOffset,
                       differentDay: sameDay ? nil : date.formatted(dayFormat))
    }

    func localTime(at date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let clockFormat = Date.VerbatimFormatStyle(
            format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            locale: .autoupdatingCurrent, timeZone: timeZone, calendar: calendar
        )
        return date.formatted(clockFormat)
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
