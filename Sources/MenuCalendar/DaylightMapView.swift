import SwiftUI

struct DaylightMapView: View {
    let palette: CalendarPalette
    @Binding var selected: WorldClockLocation?

    private let locations = WorldClockLocation.locations
    private let markerColor = Color(red: 1, green: 0.76, blue: 0.37)

    private static let renderer: EarthMapRenderer? = {
        let bundle = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main : Bundle.module
        guard let day = bundle.url(forResource: "EarthDay", withExtension: "jpg", subdirectory: "EarthTextures"),
              let night = bundle.url(forResource: "EarthNight", withExtension: "jpg", subdirectory: "EarthTextures")
        else { return nil }
        return EarthMapRenderer(dayURL: day, nightURL: night)
    }()

    var body: some View {
        TimelineView(.everyMinute) { context in
            let sun = SolarPosition(at: context.date)
            let image = Self.renderer?.image(at: context.date, sun: sun)

            VStack(spacing: 6) {
                map(image)
                cityPicker
                if let selected {
                    details(for: selected, at: context.date, sun: sun)
                }
            }
        }
    }

    private func map(_ image: CGImage?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9)

        return GeometryReader { geometry in
            if let image {
                ZStack {
                    Image(decorative: image, scale: 2)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: geometry.size.width, height: geometry.size.height)

                    ForEach(locations) { location in
                        let isSelected = location.id == selected?.id
                        marker(isSelected: isSelected)
                            .position(position(of: location, in: geometry.size))
                            .zIndex(isSelected ? 1 : 0)
                    }
                }
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { tap in
                    selectNearest(to: tap.location, in: geometry.size)
                })
                .accessibilityLabel("Earth daylight and nighttime lights")
            } else {
                Text("Map imagery is unavailable")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 137)
        .background(palette.track, in: shape)
        .clipShape(shape)
        .overlay { shape.strokeBorder(palette.outline).allowsHitTesting(false) }
    }

    private func marker(isSelected: Bool) -> some View {
        ZStack {
            if isSelected {
                Circle().fill(markerColor.opacity(0.24)).frame(width: 13, height: 13)
            }
            Circle()
                .fill(isSelected ? markerColor : Color.white.opacity(0.92))
                .overlay { Circle().strokeBorder(.black.opacity(0.42), lineWidth: 0.65) }
                .frame(width: isSelected ? 6 : 4, height: isSelected ? 6 : 4)
        }
        .accessibilityHidden(true)
    }

    private var cityPicker: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
            ForEach(locations) { location in
                let isSelected = location.id == selected?.id
                Button {
                    selected = location
                } label: {
                    Text(location.name)
                        .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? palette.text : palette.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity)
                        .frame(height: 19)
                        .background(
                            isSelected ? palette.activeTab : palette.track,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                }
                .buttonStyle(CalendarButtonStyle(palette: palette))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    private func details(for location: WorldClockLocation, at date: Date, sun: SolarPosition) -> some View {
        let reading = location.reading(at: date)
        let elevation = sun.elevation(at: location)
        let light: (label: String, symbol: String)
        if elevation >= -0.833 {
            light = ("Daylight", "sun.max.fill")
        } else if elevation >= -6 {
            light = ("Twilight", "sun.horizon.fill")
        } else {
            light = ("Night", "moon.stars.fill")
        }

        return HStack(spacing: 6) {
            Label(light.label, systemImage: light.symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(palette.secondary)

            Spacer(minLength: 4)

            Text(reading.zone)
                .font(.system(size: 9))
                .foregroundStyle(palette.secondary)

            Text(reading.time)
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(palette.text)
        }
        .padding(.horizontal, 3)
        .frame(height: 22)
        .accessibilityElement(children: .combine)
    }

    private func position(of location: WorldClockLocation, in size: CGSize) -> CGPoint {
        CGPoint(x: (location.longitude + 180) / 360 * size.width,
                y: (90 - location.latitude) / 180 * size.height)
    }

    private func selectNearest(to point: CGPoint, in size: CGSize) {
        func distance(to location: WorldClockLocation) -> CGFloat {
            let pin = position(of: location, in: size)
            return hypot(pin.x - point.x, pin.y - point.y)
        }

        if let nearest = locations.min(by: { distance(to: $0) < distance(to: $1) }),
           distance(to: nearest) < 12 {
            selected = nearest
        }
    }
}
