import SwiftUI

struct GlobeWeatherBadge: View {
    let layer: GlobeLayer
    let city: String
    let field: AppleWeatherField?
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
                if let field {
                    Text(layer.reading(field.center))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
            }
            if let field {
                scale
                Text("Sampled forecast · \(field.date.formatted(date: .omitted, time: .shortened))")
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

    private var colors: [Color] {
        switch layer {
        case .temperature: [Color(red: 0.25, green: 0.44, blue: 0.94),
                            Color(red: 0.38, green: 0.81, blue: 0.74),
                            Color(red: 1, green: 0.37, blue: 0.21)]
        case .precipitation: [Color(red: 0.36, green: 0.79, blue: 1),
                              Color(red: 0.60, green: 0.32, blue: 0.93),
                              Color(red: 1, green: 0.58, blue: 0.25)]
        default: [Color(red: 0.20, green: 0.42, blue: 0.72), Color(red: 0.24, green: 0.82, blue: 0.91)]
        }
    }

    private var labels: (String, String) {
        switch layer {
        case .temperature: ("−10°C", "35°C")
        case .precipitation: ("0.15 mm/h", "12 mm/h")
        default: ("0 mph", "75 mph")
        }
    }
}
