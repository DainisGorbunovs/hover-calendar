import Foundation

struct SolarPosition {
    let latitude: Double
    let longitude: Double

    init(at date: Date) {
        // U.S. Naval Observatory approximate solar coordinates and Greenwich mean sidereal time.
        let radians = Double.pi / 180
        let julianDate = date.timeIntervalSince1970 / 86_400 + 2_440_587.5
        let days = julianDate - 2_451_545
        let anomaly = (357.529 + 0.98560028 * days) * radians
        let eclipticLongitude = (280.459 + 0.98564736 * days
                                 + 1.915 * sin(anomaly) + 0.020 * sin(2 * anomaly)) * radians
        let obliquity = (23.439 - 0.00000036 * days) * radians
        let rightAscension = atan2(cos(obliquity) * sin(eclipticLongitude), cos(eclipticLongitude))
        latitude = asin(sin(obliquity) * sin(eclipticLongitude)) / radians

        let midnight = floor(julianDate - 0.5) + 0.5
        let hours = (julianDate - midnight) * 24
        let centuries = days / 36_525
        let siderealHours = 6.697375 + 0.065709824279 * (midnight - 2_451_545)
            + 1.0027379 * hours + 0.0854103 * centuries + 0.0000258 * centuries * centuries
        let hourAngle = rightAscension - siderealHours * 15 * radians
        longitude = atan2(sin(hourAngle), cos(hourAngle)) / radians
    }

    func elevation(at location: WorldClockLocation) -> Double {
        let radians = Double.pi / 180
        let observerLatitude = location.latitude * radians
        let declination = latitude * radians
        let longitudeDifference = (location.longitude - longitude) * radians
        let sineOfElevation = sin(observerLatitude) * sin(declination)
            + cos(observerLatitude) * cos(declination) * cos(longitudeDifference)
        return asin(min(max(sineOfElevation, -1), 1)) / radians
    }
}
