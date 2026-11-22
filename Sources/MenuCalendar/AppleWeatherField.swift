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
    /// How far a reading can travel along this layer's ramp before it clamps.
    static let windSpeedCeiling = 120.0

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

    /// Turns a 0…1 position along the ramp back into a physical value, undoing
    /// the encoding `WeatherSample.textureChannels` applies.
    func value(at position: Double) -> Double {
        switch self {
        case .daylight: 0
        case .temperature: position * 140 - 70
        case .precipitation: expm1(position * log1p(80))
        case .wind: position * Self.windSpeedCeiling
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

    var textureChannels: [UInt16] {
        func encode(_ value: Double) -> UInt16 {
            UInt16((min(1, max(0, value)) * Double(UInt16.max)).rounded())
        }

        return [
            encode((temperature + 70) / 140),
            encode(log1p(precipitation) / log1p(80)),
            encode((east + 180) / 360),
            encode((north + 180) / 360)
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
