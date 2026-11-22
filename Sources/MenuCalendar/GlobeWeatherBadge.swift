import SwiftUI

struct GlobeWeatherBadge: View {
    let layer: GlobeLayer
    let city: String
    let field: AppleWeatherField?
    let instant: Date
    let enabled: Bool
    let failed: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7)
        VStack(alignment: .leading, spacing: 4) {
            Text(layer.title)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)

            HStack(spacing: 4) {
                Text(city)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let reading = field?.center(at: instant) {
                    Text(layer.reading(reading))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
            }
            if let field {
                scale
                Text("Sampled forecast · \(instant.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.72))
                if let attribution = field.attribution {
                    Link(destination: attribution.legalPageURL) {
                        AsyncImage(url: attribution.combinedMarkLightURL) { image in
                            image.resizable().scaledToFit().frame(height: 9)
                        } placeholder: {
                            Text(attribution.serviceName).font(.system(size: 8))
                        }
                    }
                    .accessibilityLabel("Apple Weather data sources")
                }
            } else {
                Text(status)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.80))
            }
        }
        .foregroundStyle(.white)
        .frame(width: 136, alignment: .leading)
        .padding(6)
        .background(Color(white: 0.075).opacity(0.93), in: shape)
        .overlay { shape.strokeBorder(.white.opacity(0.16), lineWidth: 0.5).allowsHitTesting(false) }
    }

    private var status: String {
        if !enabled { return "WeatherKit signing required" }
        return failed ? "Apple Weather unavailable" : "Loading Apple Weather…"
    }

    private var scale: some View {
        VStack(spacing: 2) {
            Capsule()
                .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                .frame(height: 3)
            HStack {
                Text(labels.0)
                Spacer()
                Text(labels.1)
            }
            .font(.system(size: 8, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.74))
        }
        .accessibilityHidden(true)
    }

    /// The legend reads straight off the ramp the globe draws with, so the two
    /// can never disagree.
    private var colors: [Color] {
        guard let stops = layer.colorStops else { return [] }
        return stride(from: 0, through: 12, by: 1).map { step in
            let position = Double(step) / 12
            let color = WeatherColorScale.color(in: stops, at: layer.value(at: position))
            return Color(.sRGB, red: color.r, green: color.g, blue: color.b, opacity: 1)
        }
    }

    private var labels: (String, String) {
        func reading(at position: Double) -> String {
            let value = layer.value(at: position)
            switch layer {
            case .daylight: return ""
            case .temperature: return "\(Int(value.rounded()))°C"
            case .precipitation:
                return value < 10
                    ? "\(value.formatted(.number.precision(.fractionLength(1)))) mm/h"
                    : "\(Int(value.rounded())) mm/h"
            case .wind: return "\(Int((value / 1.609344).rounded())) mph"
            }
        }
        return (reading(at: 0), reading(at: 1))
    }
}
