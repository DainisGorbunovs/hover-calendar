import Foundation

/// Colour ramps for the globe's weather overlays.
///
/// The temperature and precipitation ramps are Apple Weather's own published
/// map-overlay scales, read from this Mac's cached overlay metadata at
/// `~/Library/Containers/com.apple.weather/Data/Library/Caches/MapOverlays/`.
/// Each stop pairs a physical value with an 8-bit RGBA colour, and Apple
/// interpolates linearly between neighbouring stops.
///
/// Apple's wind overlay builds its ramp in code rather than publishing it in
/// that metadata, so `wind` below is this app's own ramp. It follows the same
/// shape as the others so it can be swapped out later without touching the
/// renderer.
///
/// Regenerate with `tools/extract-weather-color-scales.py`.
enum WeatherColorScale {
    struct Stop {
        let value: Double
        let r: UInt8
        let g: UInt8
        let b: UInt8
        let a: UInt8
    }

    /// Degrees Celsius. Apple's "C" temperature scale, 14 stops over -40.0…55.0 °C.
    static let temperature: [Stop] = [
        Stop(value: -40.0, r: 48, g: 0, b: 77, a: 255),
        Stop(value: -23.33, r: 88, g: 86, b: 214, a: 255),
        Stop(value: -20.0, r: 62, g: 97, b: 226, a: 255),
        Stop(value: -12.22, r: 0, g: 122, b: 255, a: 255),
        Stop(value: -1.11, r: 90, g: 200, b: 250, a: 255),
        Stop(value: 0.0, r: 91, g: 201, b: 246, a: 255),
        Stop(value: 10.0, r: 102, g: 212, b: 207, a: 255),
        Stop(value: 20.0, r: 240, g: 205, b: 21, a: 255),
        Stop(value: 21.11, r: 255, g: 204, b: 0, a: 255),
        Stop(value: 26.67, r: 255, g: 149, b: 0, a: 255),
        Stop(value: 30.0, r: 255, g: 95, b: 29, a: 255),
        Stop(value: 32.22, r: 255, g: 59, b: 48, a: 255),
        Stop(value: 54.44, r: 119, g: 7, b: 0, a: 255),
        Stop(value: 55.0, r: 119, g: 7, b: 0, a: 255),
    ]

    /// Millimetres per hour. Apple's precipitation forecast scale, 8 stops
    /// over 0.01…205.0 mm/h. The low stops are almost transparent so light
    /// rain reads as a tint rather than a wash of colour.
    static let precipitation: [Stop] = [
        Stop(value: 0.01, r: 50, g: 173, b: 235, a: 0),
        Stop(value: 0.15, r: 50, g: 173, b: 235, a: 20),
        Stop(value: 0.32, r: 50, g: 173, b: 235, a: 140),
        Stop(value: 0.47, r: 23, g: 145, b: 246, a: 180),
        Stop(value: 0.6, r: 0, g: 122, b: 255, a: 255),
        Stop(value: 1.65, r: 175, g: 82, b: 222, a: 255),
        Stop(value: 8.0, r: 255, g: 255, b: 0, a: 255),
        Stop(value: 205.0, r: 255, g: 255, b: 255, a: 255),
    ]

    /// dBZ reflectivity. Apple's precipitation radar scale, 8 stops over
    /// 5.0…55.0 dBZ. Kept for reference; the globe renders the forecast scale.
    static let precipitationRadar: [Stop] = [
        Stop(value: 5.0, r: 90, g: 200, b: 250, a: 0),
        Stop(value: 5.1, r: 90, g: 200, b: 250, a: 25),
        Stop(value: 11.0, r: 90, g: 200, b: 250, a: 122),
        Stop(value: 16.0, r: 90, g: 200, b: 250, a: 255),
        Stop(value: 22.0, r: 0, g: 122, b: 255, a: 200),
        Stop(value: 27.0, r: 175, g: 82, b: 222, a: 220),
        Stop(value: 50.0, r: 255, g: 255, b: 0, a: 255),
        Stop(value: 55.0, r: 255, g: 255, b: 255, a: 255),
    ]

    /// Kilometres per hour. This app's own ramp, deepening with wind speed.
    static let wind: [Stop] = [
        Stop(value: 0, r: 40, g: 92, b: 160, a: 150),
        Stop(value: 12, r: 46, g: 128, b: 196, a: 170),
        Stop(value: 28, r: 54, g: 178, b: 214, a: 186),
        Stop(value: 50, r: 96, g: 214, b: 220, a: 200),
        Stop(value: 80, r: 168, g: 236, b: 236, a: 214),
        Stop(value: 120, r: 226, g: 248, b: 252, a: 226),
    ]

    /// Samples a ramp at `value`, interpolating between the two surrounding
    /// stops and clamping past either end.
    static func color(in stops: [Stop], at value: Double) -> (r: Double, g: Double, b: Double, a: Double) {
        guard let first = stops.first, let last = stops.last else { return (0, 0, 0, 0) }
        func channels(_ stop: Stop) -> (r: Double, g: Double, b: Double, a: Double) {
            (Double(stop.r) / 255, Double(stop.g) / 255, Double(stop.b) / 255, Double(stop.a) / 255)
        }
        if value <= first.value { return channels(first) }
        if value >= last.value { return channels(last) }

        for index in 1..<stops.count {
            let upper = stops[index]
            guard value <= upper.value else { continue }
            let lower = stops[index - 1]
            let span = upper.value - lower.value
            let progress = span > 0 ? (value - lower.value) / span : 0
            let start = channels(lower)
            let end = channels(upper)
            return (start.r + (end.r - start.r) * progress,
                    start.g + (end.g - start.g) * progress,
                    start.b + (end.b - start.b) * progress,
                    start.a + (end.a - start.a) * progress)
        }
        return channels(last)
    }
}
