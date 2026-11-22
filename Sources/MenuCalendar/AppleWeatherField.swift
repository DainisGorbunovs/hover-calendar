import CoreLocation
import Foundation
import Security
import WeatherKit

enum GlobeLayer: Int, CaseIterable, Identifiable {
    case daylight, temperature, precipitation, wind

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .daylight: "Daylight Globe"
        case .temperature: "Temperature"
        case .precipitation: "Precipitation"
        case .wind: "Wind"
        }
    }

    func reading(_ sample: WeatherSample) -> String {
        switch self {
        case .daylight: ""
        case .temperature: "\(Int(sample.temperature.rounded()))°C"
        case .precipitation: "\(sample.precipitation.formatted(.number.precision(.fractionLength(1)))) mm/h"
        case .wind: "\(Int((hypot(sample.east, sample.north) / 1.609344).rounded())) mph"
        }
    }
}

extension GlobeLayer {
    var colorStops: [WeatherColorScale.Stop]? {
        switch self {
        case .daylight: nil
        case .temperature: WeatherColorScale.temperature
        case .precipitation: WeatherColorScale.precipitation
        case .wind: WeatherColorScale.wind
        }
    }

    /// Scales the ramp's own alpha so the terrain still reads through a layer
    /// whose colours are fully opaque.
    var overlayOpacity: Double {
        switch self {
        case .daylight: 0
        case .temperature: 0.64
        case .precipitation, .wind: 1
        }
    }

    /// The range of readings the sample texture stores for this layer, taken
    /// from the ramp itself so the two cannot drift apart. Temperature spans
    /// its ramp exactly, the way Apple's own scale does; precipitation and
    /// wind both start at nothing and run to the top of the ramp.
    var domain: ClosedRange<Double> {
        guard let stops = colorStops, let first = stops.first, let last = stops.last,
              first.value < last.value else { return 0...1 }
        switch self {
        case .temperature: return first.value...last.value
        case .precipitation, .wind: return 0...last.value
        case .daylight: return 0...1
        }
    }

    /// Places a reading on its ramp as a 0…1 position, clamping past either end.
    ///
    /// Precipitation follows a logarithmic curve so the ordinary millimetre or
    /// two keeps most of the ramp, rather than being crushed against one end by
    /// the cloudburst at the top of the scale.
    func encode(_ reading: Double) -> Double {
        let range = domain
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        switch self {
        case .precipitation:
            return log1p(max(0, reading)) / log1p(range.upperBound)
        default:
            return min(1, max(0, (reading - range.lowerBound) / span))
        }
    }

    /// Turns a 0…1 position back into a reading, undoing `encode`.
    func value(at position: Double) -> Double {
        let range = domain
        switch self {
        case .precipitation:
            return expm1(position * log1p(range.upperBound))
        default:
            return range.lowerBound + position * (range.upperBound - range.lowerBound)
        }
    }
}

struct GlobeMenu {
    let reset: (() -> Void)?
    let layer: GlobeLayer
    let selectLayer: ((GlobeLayer) -> Void)?
}

struct WeatherRegion: Hashable, Sendable {
    static let side = 5
    static let mapZoom = 14.0
    let latitude: Double
    let longitude: Double

    init(around city: WorldClockLocation) {
        latitude = min(84, max(-84, (city.latitude * 4).rounded() / 4))
        longitude = (city.longitude * 4).rounded() / 4
    }

    var latitudeSpan: Double { 10.1 }
    var longitudeSpan: Double { min(64, 1.25 * latitudeSpan / max(0.15, cos(latitude * .pi / 180))) }
    var north: Double { latitude + latitudeSpan / 2 }
    var west: Double { longitude - longitudeSpan / 2 }

    func coordinate(row: Int, column: Int) -> (latitude: Double, longitude: Double) {
        let lat = north - Double(row) * latitudeSpan / Double(Self.side - 1)
        let lon = west + Double(column) * longitudeSpan / Double(Self.side - 1)
        return (lat, lon >= 180 ? lon - 360 : lon < -180 ? lon + 360 : lon)
    }
}

struct WeatherSample: Sendable {
    let temperature: Double
    let precipitation: Double
    let east: Double
    let north: Double

    /// How far either wind component can reach before it clamps, in km/h.
    static let windComponentLimit = 180.0

    var textureChannels: [UInt16] {
        func channel(_ position: Double) -> UInt16 {
            UInt16((min(1, max(0, position)) * Double(UInt16.max)).rounded())
        }

        // Temperature and precipitation are stored on their ramps. Wind keeps
        // its two components signed, and the globe turns them back into a
        // speed before looking that up on the wind ramp.
        let limit = Self.windComponentLimit
        return [
            channel(GlobeLayer.temperature.encode(temperature)),
            channel(GlobeLayer.precipitation.encode(precipitation)),
            channel((east + limit) / (2 * limit)),
            channel((north + limit) / (2 * limit))
        ]
    }
}

/// One hour of the forecast across the region's grid, in row-major order.
struct WeatherFrame: Sendable {
    let date: Date
    let samples: [WeatherSample]

    var center: WeatherSample { samples[samples.count / 2] }
}

struct AppleWeatherField: Sendable {
    /// How many hours of forecast to keep. Apple's own map asks for a similar
    /// span either side of now.
    static let frameLimit = 13

    /// Whether the readings vary across the region, or are one place's
    /// forecast standing in for all of it.
    enum Coverage: Sendable { case grid, point }

    let region: WeatherRegion
    let frames: [WeatherFrame]
    let attribution: WeatherAttribution?
    var coverage = Coverage.grid

    var date: Date { frames.first?.date ?? .distantPast }

    /// The two frames `instant` falls between, and how far across it sits.
    /// Outside the forecast both frames are the nearest one, so the blend
    /// holds still rather than extrapolating.
    func bracket(at instant: Date) -> (earlier: WeatherFrame, later: WeatherFrame, progress: Double)? {
        guard let first = frames.first, let last = frames.last else { return nil }
        if instant <= first.date { return (first, first, 0) }
        if instant >= last.date { return (last, last, 0) }

        for index in 1..<frames.count {
            let later = frames[index]
            guard instant < later.date else { continue }
            let earlier = frames[index - 1]
            let span = later.date.timeIntervalSince(earlier.date)
            guard span > 0 else { return (earlier, earlier, 0) }
            let progress = instant.timeIntervalSince(earlier.date) / span
            return (earlier, later, min(1, max(0, progress)))
        }
        return (last, last, 0)
    }

    /// The reading at the middle of the grid, blended the same way the globe
    /// blends the overlay, so the badge and the colours agree.
    func center(at instant: Date) -> WeatherSample? {
        guard let bracket = bracket(at: instant) else { return nil }
        let earlier = bracket.earlier.center
        let later = bracket.later.center
        func blend(_ a: Double, _ b: Double) -> Double { a + (b - a) * bracket.progress }
        return WeatherSample(temperature: blend(earlier.temperature, later.temperature),
                             precipitation: blend(earlier.precipitation, later.precipitation),
                             east: blend(earlier.east, later.east),
                             north: blend(earlier.north, later.north))
    }
}

actor AppleWeatherService {
    static let shared = AppleWeatherService()

    static let entitled: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.weatherkit" as CFString, nil) as? Bool == true
    }()

    enum Problem: Error {
        case invalidReading
        /// Without WeatherKit, a city only has weather if Weather tracks it.
        case placeNotTracked
    }

    private var cache: [WeatherRegion: (field: AppleWeatherField, fetched: Date, lifetime: TimeInterval)] = [:]
    private var requests: [WeatherRegion: Task<AppleWeatherField, Error>] = [:]
    private var attribution: WeatherAttribution?

    /// A fetch stays useful for far longer than it used to: it brings back
    /// hours of forecast, and the globe reads the current moment out of it
    /// rather than redrawing a snapshot. Holding it an hour keeps the display
    /// current while asking WeatherKit for a quarter as much.
    private static let cacheLifetime = 60.0 * 60

    /// Reading the store costs nothing but a local query, and weatherd keeps
    /// revising it, so look again far sooner.
    private static let storeLifetime = 10.0 * 60

    func field(for region: WeatherRegion) async throws -> AppleWeatherField {
        let now = Date.now
        cache = cache.filter { now.timeIntervalSince($0.value.fetched) < $0.value.lifetime }
        if let existing = cache[region] { return existing.field }

        guard Self.entitled else {
            let field = try Self.storedField(for: region)
            cache[region] = (field, .now, Self.storeLifetime)
            return field
        }
        if let running = requests[region] { return try await running.value }

        let running = Task { try await fetch(region) }
        requests[region] = running
        defer { requests[region] = nil }
        let field = try await running.value
        cache[region] = (field, .now, Self.cacheLifetime)
        return field
    }

    /// Apple's forecast for the tracked place at the middle of the region,
    /// standing in for the whole grid.
    static func storedField(for region: WeatherRegion) throws -> AppleWeatherField {
        guard let hours = AppleWeatherStore.hours(nearLatitude: region.latitude,
                                                  longitude: region.longitude)
        else { throw Problem.placeNotTracked }

        let cells = WeatherRegion.side * WeatherRegion.side
        let frames = hours.prefix(AppleWeatherField.frameLimit).map { hour in
            let bearing = hour.windDirection * .pi / 180
            let sample = WeatherSample(temperature: hour.temperature,
                                       precipitation: hour.precipitation,
                                       east: -sin(bearing) * hour.windSpeed,
                                       north: -cos(bearing) * hour.windSpeed)
            return WeatherFrame(date: hour.date, samples: Array(repeating: sample, count: cells))
        }
        var field = AppleWeatherField(region: region, frames: Array(frames), attribution: nil)
        field.coverage = .point
        return field
    }

    private func fetch(_ region: WeatherRegion) async throws -> AppleWeatherField {
        let service = WeatherService.shared
        let mark: WeatherAttribution
        if let attribution {
            mark = attribution
        } else {
            mark = try await service.attribution
            attribution = mark
        }

        // One hourly forecast per grid point, which is a single request each,
        // the same cost as asking for the current conditions alone.
        var grid: [[Date: WeatherSample]] = []
        for row in 0..<WeatherRegion.side {
            let columns = try await withThrowingTaskGroup(of: (Int, [Date: WeatherSample]).self) { group in
                for column in 0..<WeatherRegion.side {
                    let coordinate = region.coordinate(row: row, column: column)
                    group.addTask {
                        let place = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                        let forecast = try await service.weather(for: place, including: .hourly)
                        var hours: [Date: WeatherSample] = [:]
                        for hour in forecast {
                            let speed = hour.wind.speed.converted(to: .kilometersPerHour).value
                            let direction = hour.wind.direction.converted(to: .radians).value
                            // An hour's accumulation in millimetres is an
                            // intensity in mm/h, which is what the scale wants.
                            let amount = hour.precipitationAmount.converted(to: .millimeters).value
                            let temperature = hour.temperature.converted(to: .celsius).value
                            guard temperature.isFinite, amount.isFinite, speed.isFinite, direction.isFinite
                            else { continue }
                            hours[hour.date] = WeatherSample(
                                temperature: temperature,
                                precipitation: max(0, amount),
                                east: -sin(direction) * speed,
                                north: -cos(direction) * speed
                            )
                        }
                        return (column, hours)
                    }
                }
                var values: [(Int, [Date: WeatherSample])] = []
                for try await result in group { values.append(result) }
                return values.sorted { $0.0 < $1.0 }
            }
            grid.append(contentsOf: columns.map { $0.1 })
        }

        return AppleWeatherField(region: region, frames: Self.frames(from: grid), attribution: mark)
    }

    /// Turns one hourly series per grid point into whole-grid frames, keeping
    /// only the hours every point reported so no frame has a hole in it.
    private static func frames(from grid: [[Date: WeatherSample]]) -> [WeatherFrame] {
        guard let first = grid.first else { return [] }
        let shared = first.keys
            .filter { date in grid.allSatisfy { $0[date] != nil } }
            .sorted()
        // Keep the hour we are in, so the blend has something to start from.
        let start = Date.now.addingTimeInterval(-3600)
        return shared
            .drop { $0 < start }
            .prefix(AppleWeatherField.frameLimit)
            .map { date in WeatherFrame(date: date, samples: grid.map { $0[date]! }) }
    }
}
