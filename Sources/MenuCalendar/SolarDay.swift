import Foundation

struct SolarDay {
    let interval: DateInterval
    let sunrise: Date?
    let sunset: Date?
    let daylight: [DateInterval]

    init?(at date: Date, in city: WorldClockLocation) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = city.timeZone
        guard let interval = calendar.dateInterval(of: .day, for: date) else { return nil }

        func isSunUp(_ instant: Date) -> Bool {
            SolarPosition(at: instant).elevation(at: city) >= SolarPosition.sunriseElevation
        }

        // Search the city's civil day, then refine each horizon crossing to within one second.
        var previous = interval.start
        var sunUp = isSunUp(previous)
        var daylightStart: Date? = sunUp ? previous : nil
        var rise: Date?
        var set: Date?
        var periods: [DateInterval] = []

        while previous < interval.end {
            let next = min(interval.end, previous.addingTimeInterval(30 * 60))
            let nextSunUp = isSunUp(next)
            if sunUp != nextSunUp {
                var lower = previous
                var upper = next
                while upper.timeIntervalSince(lower) > 1 {
                    let middle = lower.addingTimeInterval(upper.timeIntervalSince(lower) / 2)
                    if isSunUp(middle) == sunUp {
                        lower = middle
                    } else {
                        upper = middle
                    }
                }
                if nextSunUp {
                    rise = rise ?? upper
                    daylightStart = upper
                } else {
                    set = set ?? upper
                    if let start = daylightStart { periods.append(DateInterval(start: start, end: upper)) }
                    daylightStart = nil
                }
            }
            previous = next
            sunUp = nextSunUp
        }
        if let start = daylightStart { periods.append(DateInterval(start: start, end: interval.end)) }

        self.interval = interval
        sunrise = rise
        sunset = set
        daylight = periods
    }

    func fraction(at date: Date) -> Double {
        min(1, max(0, date.timeIntervalSince(interval.start) / interval.duration))
    }
}
