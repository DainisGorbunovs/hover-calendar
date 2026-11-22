import SwiftUI

struct GlobeSolarBadge: View, Equatable {
    let city: WorldClockLocation
    let instant: Date

    private let amber = Color(red: 1, green: 0.76, blue: 0.44)

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.city == rhs.city && lhs.instant == rhs.instant
    }

    var body: some View {
        let elevation = SolarPosition(at: instant).elevation(at: city)
        let sunUp = elevation >= SolarPosition.sunriseElevation
        let twilight = !sunUp && elevation >= -6
        let light = sunUp ? "Daylight" : twilight ? "Twilight" : "Night"
        let day = SolarDay(at: instant, in: city)
        let accessibility = [
            city.name,
            light,
            day?.sunrise.map { "Sunrise \(city.localTime(at: $0))" },
            day?.sunset.map { "Sunset \(city.localTime(at: $0))" }
        ].compactMap { $0 }.joined(separator: ", ")
        let shape = RoundedRectangle(cornerRadius: 7)

        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(city.name)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 5)

                Label(light, systemImage: sunUp ? "sun.max.fill" : twilight ? "sun.horizon" : "moon.stars")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(sunUp || twilight ? amber : Color.white.opacity(0.72))
            }

            if let day {
                dayStrip(day)
                HStack {
                    if let rise = day.sunrise {
                        Label(city.localTime(at: rise), systemImage: "sunrise")
                    }
                    Spacer(minLength: 0)
                    if let set = day.sunset {
                        Label(city.localTime(at: set), systemImage: "sunset")
                    }
                }
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.76))
            }
        }
        .foregroundStyle(.white)
        .frame(width: 130)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(Color(white: 0.095).opacity(0.9), in: shape)
        .overlay { shape.strokeBorder(.white.opacity(0.15), lineWidth: 0.5) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }

    private func dayStrip(_ day: SolarDay) -> some View {
        GeometryReader { geometry in
            // Reserve space for the time marker at each end.
            let width = max(0, geometry.size.width - 6)
            let marker = day.fraction(at: instant) * width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.22))
                    .frame(width: width, height: 2)

                ForEach(day.daylight, id: \.start) { interval in
                    let start = day.fraction(at: interval.start)
                    let end = day.fraction(at: interval.end)

                    Capsule()
                        .fill(amber.opacity(0.9))
                        .frame(width: (end - start) * width, height: 2)
                        .offset(x: start * width)
                }

                Circle()
                    .fill(.white)
                    .shadow(color: amber.opacity(0.65), radius: 2)
                    .frame(width: 5, height: 5)
                    .offset(x: marker - 2.5)
            }
            .padding(.leading, 3)
            .frame(height: geometry.size.height)
        }
        .frame(height: 7)
        .accessibilityHidden(true)
    }
}
