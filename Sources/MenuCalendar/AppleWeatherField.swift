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
        // Apple's wind blue is opaque; its map draws coastlines on top, and the
        // globe has none, so let the land show faintly through instead.
        case .wind: 0.8
        case .precipitation: 1
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
    /// Tells one fetch from another, so a refreshed forecast for the same
    /// region and hours is drawn afresh rather than from the old one's uploads.
    let identity = UUID()

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
        /// No grid could be had, and Weather does not track a place here.
        case placeNotTracked
        /// The shortcut is installed but its run failed, and Weather does not
        /// track a place here either.
        case shortcutFailed
        /// The installed shortcut predates the answer format this build reads.
        case shortcutOutdated
    }

    private struct Fetched {
        let field: AppleWeatherField
        let lifetime: TimeInterval
    }

    private enum ShortcutOutcome {
        case grid(AppleWeatherField)
        case missing, outdated, failed
        /// A newer region was asked for before this run could start.
        case superseded
    }

    private var cache: [WeatherRegion: (fetched: Fetched, at: Date)] = [:]
    private var requests: [WeatherRegion: Task<Fetched, Error>] = [:]
    private var attribution: WeatherAttribution?

    /// The latest grid for each region, kept past its cache lifetime so a
    /// failed refresh can fall back on it while its hours still lie ahead.
    private var lastGrid: [WeatherRegion: AppleWeatherField] = [:]
    /// When the shortcut was last found missing, outdated or failing. Each
    /// costs a process to rediscover, so wait a while before asking again.
    private var shortcutMissingSince: Date?
    private var shortcutOutdatedSince: Date?
    private var shortcutFailedSince: Date?
    /// The run in progress, so Shortcuts is only ever asked one grid at a time.
    private var shortcutQueue: Task<Void, Never>?
    /// The region most recently asked for. A queued run for any other region
    /// is skipped when its turn comes, because the user has moved on.
    private var latestShortcutRegion: WeatherRegion?
    private var latestShortcutRequest = Date.distantPast
    /// The region the shortcut is fetching right now, if any.
    private var runningShortcutRegion: WeatherRegion?

    /// A fetch stays useful for far longer than it used to: it brings back
    /// hours of forecast, and the globe reads the current moment out of it
    /// rather than redrawing a snapshot. Holding it an hour keeps the display
    /// current while asking for a quarter as much.
    private static let cacheLifetime = 60.0 * 60

    /// Reading the store costs nothing but a local query, and weatherd keeps
    /// revising it, so look again far sooner. A grid from the shortcut, once it
    /// has been added, replaces it within this long.
    private static let storeLifetime = 10.0 * 60
    private static let shortcutRecheck = 5.0 * 60
    private static let shortcutBackoff = 3.0 * 60
    /// How long a region must stay wanted before its run starts.
    private static let shortcutSettle = 0.6

    /// The best forecast this build can get for the region: WeatherKit's grid
    /// when signed for it; otherwise the shortcut's grid, if the user added it;
    /// otherwise Weather's forecast for a place it tracks there, as a halo.
    func field(for region: WeatherRegion) async throws -> AppleWeatherField {
        if let cached = cachedField(for: region) { return cached }
        if let running = requests[region] { return try await running.value.field }

        let running = Task { try await best(for: region) }
        requests[region] = running
        defer { requests[region] = nil }
        let fetched = try await running.value
        cache[region] = (fetched, .now)
        return fetched.field
    }

    /// What is already to hand for the region, without fetching anything.
    func cachedField(for region: WeatherRegion) -> AppleWeatherField? {
        let now = Date.now
        cache = cache.filter { now.timeIntervalSince($0.value.at) < $0.value.fetched.lifetime }
        return cache[region]?.fetched.field
    }

    private func best(for region: WeatherRegion) async throws -> Fetched {
        if Self.entitled {
            return Fetched(field: try await fetch(region), lifetime: Self.cacheLifetime)
        }
        let outcome = await shortcutField(for: region)
        switch outcome {
        case .grid(let grid):
            lastGrid[region] = grid
            return Fetched(field: grid, lifetime: Self.cacheLifetime)
        case .superseded:
            throw CancellationError()
        case .missing, .outdated, .failed:
            break
        }
        // Keep showing an earlier grid while it still has hours to come,
        // rather than falling back to a single point.
        if let grid = lastGrid[region], let last = grid.frames.last, last.date > .now {
            return Fetched(field: grid, lifetime: Self.storeLifetime)
        }
        do {
            return Fetched(field: try Self.storedField(for: region), lifetime: Self.storeLifetime)
        } catch {
            switch outcome {
            case .outdated: throw Problem.shortcutOutdated
            case .failed: throw Problem.shortcutFailed
            default: throw Problem.placeNotTracked
            }
        }
    }

    private static func recent(_ date: Date?, within interval: TimeInterval) -> Bool {
        date.map { Date.now.timeIntervalSince($0) < interval } ?? false
    }

    /// Whether a queued run should still start: its region is still the one
    /// wanted, and nothing learnt while it waited rules the shortcut out.
    private func shouldStartShortcut(for region: WeatherRegion) -> Bool {
        latestShortcutRegion == region
            && !Self.recent(shortcutMissingSince, within: Self.shortcutRecheck)
            && !Self.recent(shortcutOutdatedSince, within: Self.shortcutRecheck)
    }

    /// The region's grid from the user's shortcut, or why there is none.
    private func shortcutField(for region: WeatherRegion) async -> ShortcutOutcome {
        if Self.recent(shortcutMissingSince, within: Self.shortcutRecheck) { return .missing }
        if Self.recent(shortcutOutdatedSince, within: Self.shortcutRecheck) { return .outdated }
        if Self.recent(shortcutFailedSince, within: Self.shortcutBackoff) { return .failed }

        latestShortcutRegion = region
        latestShortcutRequest = .now
        // A run for a region the user has left would only make this one wait.
        if let running = runningShortcutRegion, running != region {
            ShortcutWeather.supersedeRunning()
        }
        let previous = shortcutQueue
        let run = Task { () throws -> [[Date: WeatherSample]] in
            await previous?.value
            // Start only once the user has settled on the region: passing over
            // cities on the way to another should not spawn a run for each.
            guard self.shouldStartShortcut(for: region) else { throw CancellationError() }
            let unsettled = Self.shortcutSettle - Date.now.timeIntervalSince(self.latestShortcutRequest)
            if unsettled > 0 { try await Task.sleep(nanoseconds: UInt64(unsettled * 1_000_000_000)) }
            guard self.shouldStartShortcut(for: region) else { throw CancellationError() }
            self.runningShortcutRegion = region
            defer { self.runningShortcutRegion = nil }
            return try await ShortcutWeather.forecasts(for: region)
        }
        shortcutQueue = Task { _ = try? await run.value }

        do {
            let frames = Self.frames(from: try await run.value)
            shortcutMissingSince = nil
            shortcutOutdatedSince = nil
            guard !frames.isEmpty else {
                shortcutFailedSince = .now
                return .failed
            }
            shortcutFailedSince = nil
            return .grid(AppleWeatherField(region: region, frames: frames, attribution: nil))
        } catch is CancellationError {
            return Self.recent(shortcutMissingSince, within: Self.shortcutRecheck) ? .missing
                : Self.recent(shortcutOutdatedSince, within: Self.shortcutRecheck) ? .outdated : .superseded
        } catch ShortcutWeather.Failure.notInstalled {
            shortcutMissingSince = .now
            return .missing
        } catch ShortcutWeather.Failure.outdated {
            shortcutOutdatedSince = .now
            return .outdated
        } catch {
            shortcutFailedSince = .now
            // The kind of failure only: Shortcuts' own message can name places.
            NSLog("Menu Calendar weather shortcut failed: %@", ShortcutWeather.describe(error))
            return .failed
        }
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
    static func frames(from grid: [[Date: WeatherSample]]) -> [WeatherFrame] {
        guard !grid.isEmpty else { return [] }
        // Shortcuts starts each point's hours at that point's local hour, so
        // in a half-hour time zone a point can begin an hour after the rest.
        // Let its first hour stand in for the one before, rather than lose the
        // current hour for the whole grid.
        var grid = grid
        if let earliest = grid.compactMap({ $0.keys.min() }).min() {
            let next = earliest.addingTimeInterval(3600)
            for index in grid.indices where grid[index][earliest] == nil {
                if let sample = grid[index][next] { grid[index][earliest] = sample }
            }
        }
        let first = grid[0]
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
