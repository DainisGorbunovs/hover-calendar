import Foundation
import SQLite3

/// Apple Weather's hourly forecasts for the places Weather keeps up to date.
///
/// `weatherd` refreshes the forecast for every location saved in Weather, so
/// its widgets stay current, and keeps them in an unencrypted SQLite store in
/// the user's own Library. Reading that store gives Apple's forecast for those
/// places without a WeatherKit entitlement and without a request of our own.
///
/// It only holds the places Weather tracks, so it supplies a single point per
/// city rather than a grid. The globe draws such a field as a halo around the
/// city instead of pretending it covers the region.
enum AppleWeatherStore {
    struct Hour: Sendable {
        let date: Date
        let temperature: Double      // °C
        let precipitation: Double    // mm in the hour, so mm/h
        let windSpeed: Double        // km/h
        let windDirection: Double    // degrees, the bearing the wind blows from
    }

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Weather/weather-data.db")

    /// How far a saved place can sit from the city it stands in for.
    static let matchRadius = 40.0   // km

    /// Each hour is a fixed-size packed record. Any other size is a layout this
    /// reader does not know, and is skipped rather than misread.
    private static let recordLength = 164

    private enum Offset {
        static let startsAt = 0
        static let precipitation = 50
        static let pressure = 77
        static let temperature = 96
        static let windDirection = 139
        static let windSpeed = 156
    }

    /// The forecast for the saved place nearest the given coordinate, from an
    /// hour ago onwards, or nil when Weather does not track anywhere close.
    static func hours(nearLatitude latitude: Double, longitude: Double,
                      from start: Date = .now.addingTimeInterval(-3600)) -> [Hour]? {
        var database: OpaquePointer?
        let uri = "file:\(url.path)?mode=ro"
        guard sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK
        else {
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)

        guard let place = nearestPlace(in: database, latitude: latitude, longitude: longitude)
        else { return nil }

        let query = "select model from hourForecast where id = ? and startsAt >= ? order by startsAt"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, place, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_double(statement, 2, start.timeIntervalSince1970)

        var hours: [Hour] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
            let record = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            if let hour = decode(record) { hours.append(hour) }
        }
        return hours.isEmpty ? nil : hours
    }

    /// The id of the tracked place closest to the coordinate, within range.
    private static func nearestPlace(in database: OpaquePointer?, latitude: Double,
                                     longitude: Double) -> String? {
        let query = "select distinct id, latitude, longitude from hourForecast"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        var best: (id: String, distance: Double)?
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { continue }
            let distance = kilometres(from: (latitude, longitude),
                                      to: (sqlite3_column_double(statement, 1),
                                           sqlite3_column_double(statement, 2)))
            if distance <= matchRadius, distance < best?.distance ?? .infinity {
                best = (String(cString: text), distance)
            }
        }
        return best?.id
    }

    static func decode(_ record: Data) -> Hour? {
        guard record.count == recordLength else { return nil }
        func double(_ offset: Int) -> Double {
            record.withUnsafeBytes { Double(bitPattern: UInt64(littleEndian: $0.loadUnaligned(
                fromByteOffset: offset, as: UInt64.self))) }
        }
        func integer(_ offset: Int) -> Int64 {
            record.withUnsafeBytes { Int64(littleEndian: $0.loadUnaligned(
                fromByteOffset: offset, as: Int64.self)) }
        }

        // Sea-level pressure is the canary: it only ever reads 900–1100 hPa
        // where the layout is the one this reader expects.
        guard (900...1100).contains(double(Offset.pressure)) else { return nil }

        let hour = Hour(date: Date(timeIntervalSince1970: double(Offset.startsAt)),
                        temperature: double(Offset.temperature),
                        precipitation: double(Offset.precipitation),
                        windSpeed: double(Offset.windSpeed),
                        windDirection: Double(integer(Offset.windDirection)))
        guard (-90...70).contains(hour.temperature),
              (0...500).contains(hour.precipitation),
              (0...500).contains(hour.windSpeed),
              (0...360).contains(hour.windDirection)
        else { return nil }
        return hour
    }

    private static func kilometres(from a: (Double, Double), to b: (Double, Double)) -> Double {
        let radians = Double.pi / 180
        let dLat = (b.0 - a.0) * radians
        let dLon = (b.1 - a.1) * radians
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.0 * radians) * cos(b.0 * radians) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * 6371 * asin(min(1, sqrt(h)))
    }
}
