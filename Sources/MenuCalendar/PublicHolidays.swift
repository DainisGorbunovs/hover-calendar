import Foundation

enum HolidayRegion: String, CaseIterable, Identifiable {
    case unitedStates = "united-states"
    case englandAndWales = "england-and-wales"
    case scotland
    case northernIreland = "northern-ireland"

    var id: String { rawValue }

    static var localDefault: HolidayRegion {
        Locale.autoupdatingCurrent.region?.identifier == "GB" ? .englandAndWales : .unitedStates
    }

    var title: String {
        switch self {
        case .unitedStates: "U.S. federal holidays"
        case .englandAndWales: "England and Wales"
        case .scotland: "Scotland"
        case .northernIreland: "Northern Ireland"
        }
    }

    var abbreviation: String {
        switch self {
        case .unitedStates: "US"
        case .englandAndWales: "E&W"
        case .scotland: "SCO"
        case .northernIreland: "NI"
        }
    }
}

struct HolidayDay: Hashable, Comparable {
    let year: Int
    let month: Int
    let day: Int

    init(_ date: Date, in calendar: Calendar) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        year = parts.year ?? 0
        month = parts.month ?? 0
        day = parts.day ?? 0
    }

    init?(iso: String) {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        year = parts[0]
        month = parts[1]
        day = parts[2]
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

struct PublicHolidays {
    private struct Schedule: Decodable {
        let events: [Event]
    }

    private struct Event: Decodable {
        let date: String
        let title: String
        let notes: String
    }

    private static let uk: [String: [HolidayDay: [String]]] = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main : Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "UKBankHolidays", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let schedules = try? JSONDecoder().decode([String: Schedule].self, from: data) else { return [:] }
        return schedules.mapValues { schedule in
            var holidays: [HolidayDay: [String]] = [:]
            for event in schedule.events {
                guard let date = HolidayDay(iso: event.date) else { continue }
                let label = event.notes.isEmpty || event.title.localizedCaseInsensitiveContains(event.notes)
                    ? event.title : "\(event.title) (\(event.notes))"
                holidays[date, default: []].append(label)
            }
            return holidays
        }
    }()

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    let calendar: Calendar
    let dates: [HolidayDay: [String]]
    let coveredYears: ClosedRange<Int>?

    init(region: HolidayRegion, days: [Date], timeZone: TimeZone) {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        calendar = local

        if region == .unitedStates {
            // Include adjacent years for observed New Year's Day on December 31.
            let years = Set(days.flatMap { day -> [Int] in
                let year = local.component(.year, from: day)
                return [year - 1, year, year + 1]
            })
            dates = years.sorted().reduce(into: [:]) { result, year in
                for (date, names) in Self.federalDates(in: year) {
                    result[date, default: []].append(contentsOf: names)
                }
            }
            coveredYears = 1997...Int.max
        } else {
            let records = Self.uk[region.rawValue] ?? [:]
            dates = records
            let years = records.keys.map(\.year)
            coveredYears = years.min().flatMap { first in years.max().map { first...$0 } }
        }
    }

    func names(on date: Date) -> [String] {
        dates[HolidayDay(date, in: calendar)] ?? []
    }

    // Nationwide U.S. federal holiday rules for the ordinary Monday–Friday schedule.
    private static func federalDates(in year: Int) -> [HolidayDay: [String]] {
        guard year >= 1997 else { return [:] }
        var holidays: [HolidayDay: [String]] = [:]

        func add(_ name: String, on date: Date) {
            holidays[HolidayDay(date, in: utc), default: []].append(name)
        }

        func fixed(_ name: String, month: Int, day: Int) {
            guard let date = utc.date(from: DateComponents(year: year, month: month, day: day)) else { return }
            add(name, on: date)
            let weekday = utc.component(.weekday, from: date)
            let adjustment = weekday == 7 ? -1 : weekday == 1 ? 1 : 0
            if adjustment != 0, let observed = utc.date(byAdding: .day, value: adjustment, to: date) {
                add("\(name) (observed)", on: observed)
            }
        }

        func weekday(_ name: String, month: Int, weekday: Int = 2, ordinal: Int) {
            let parts = DateComponents(year: year, month: month, weekday: weekday, weekdayOrdinal: ordinal)
            if let date = utc.date(from: parts) { add(name, on: date) }
        }

        fixed("New Year’s Day", month: 1, day: 1)
        weekday("Martin Luther King Jr. Day", month: 1, ordinal: 3)
        weekday("Washington’s Birthday", month: 2, ordinal: 3)
        weekday("Memorial Day", month: 5, ordinal: -1)
        if year >= 2021 { fixed("Juneteenth National Independence Day", month: 6, day: 19) }
        fixed("Independence Day", month: 7, day: 4)
        weekday("Labor Day", month: 9, ordinal: 1)
        weekday("Columbus Day", month: 10, ordinal: 2)
        fixed("Veterans Day", month: 11, day: 11)
        weekday("Thanksgiving Day", month: 11, weekday: 5, ordinal: 4)
        fixed("Christmas Day", month: 12, day: 25)
        return holidays
    }
}
