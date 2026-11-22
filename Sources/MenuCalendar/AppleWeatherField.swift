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

struct AppleWeatherField: Sendable {
    let region: WeatherRegion
    let samples: [WeatherSample]
    let date: Date
    let attribution: WeatherAttribution?

    var center: WeatherSample { samples[samples.count / 2] }
}

actor AppleWeatherService {
    static let shared = AppleWeatherService()

    static let entitled: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.weatherkit" as CFString, nil) as? Bool == true
    }()

    private enum SamplingError: Error { case invalidReading }

    private var cache: [WeatherRegion: (field: AppleWeatherField, fetched: Date)] = [:]
    private var requests: [WeatherRegion: Task<AppleWeatherField, Error>] = [:]
    private var attribution: WeatherAttribution?

    func field(for region: WeatherRegion) async throws -> AppleWeatherField {
        let now = Date.now
        cache = cache.filter { now.timeIntervalSince($0.value.fetched) < 15 * 60 }
        if let existing = cache[region] { return existing.field }
        if let running = requests[region] { return try await running.value }

        let running = Task { try await fetch(region) }
        requests[region] = running
        defer { requests[region] = nil }
        let field = try await running.value
        cache[region] = (field, .now)
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

        var samples: [WeatherSample] = []
        var date = Date.distantFuture
        for row in 0..<WeatherRegion.side {
            let columns = try await withThrowingTaskGroup(of: (Int, Date, WeatherSample).self) { group in
                for column in 0..<WeatherRegion.side {
                    let coordinate = region.coordinate(row: row, column: column)
                    group.addTask {
                        let place = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                        let weather = try await service.weather(for: place, including: .current)
                        let speed = weather.wind.speed.converted(to: .kilometersPerHour).value
                        let direction = weather.wind.direction.converted(to: .radians).value
                        let amount = weather.precipitationIntensity.converted(to: .kilometersPerHour).value * 1_000_000
                        let temperature = weather.temperature.converted(to: .celsius).value
                        guard temperature.isFinite, amount.isFinite, speed.isFinite, direction.isFinite else {
                            throw SamplingError.invalidReading
                        }
                        let sample = WeatherSample(
                            temperature: temperature,
                            precipitation: max(0, amount),
                            east: -sin(direction) * speed,
                            north: -cos(direction) * speed
                        )
                        return (column, weather.date, sample)
                    }
                }
                var values: [(Int, Date, WeatherSample)] = []
                for try await result in group { values.append(result) }
                return values.sorted { $0.0 < $1.0 }
            }
            for (_, timestamp, sample) in columns {
                date = min(date, timestamp)
                samples.append(sample)
            }
        }
        return AppleWeatherField(region: region, samples: samples, date: date, attribution: mark)
    }
}
