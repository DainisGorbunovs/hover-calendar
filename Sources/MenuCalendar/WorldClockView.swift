import SwiftUI

struct WorldClockView: View {
    let palette: CalendarPalette
    let selectedCity: String?
    let focusCity: (WorldClockLocation, Bool) -> Void

    @State private var previewTask: Task<Void, Never>?
    @State private var hoveredCity: String?

    var body: some View {
        TimelineView(.everyMinute) { context in
            let locations = WorldClockLocation.orderedByLocalTime(at: context.date)
            let sun = SolarPosition(at: context.date)
            HStack(spacing: 0) {
                ForEach(locations) { location in
                    clock(location, at: context.date, elevation: sun.elevation(at: location))
                    if location.id != locations.last?.id {
                        Rectangle()
                            .fill(palette.outline)
                            .frame(width: 0.5, height: 39)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(2)
            .background(palette.track, in: RoundedRectangle(cornerRadius: 7))
        }
        .onDisappear { previewTask?.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("World clocks")
    }

    private func clock(_ location: WorldClockLocation, at date: Date, elevation: Double) -> some View {
        let reading = location.reading(at: date)
        let selected = location.id == selectedCity
        let zone = [reading.zone, reading.differentDay].compactMap { $0 }.joined(separator: " · ")

        return Button {
            previewTask?.cancel()
            focusCity(location, true)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text(location.flag)
                        .font(.system(size: 10))
                        .accessibilityHidden(true)
                    Text(location.name)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(palette.text)

                HStack(spacing: 3) {
                    Text(reading.time)
                        .font(.system(size: 17, weight: .medium).monospacedDigit())
                        .foregroundStyle(palette.text)
                    Spacer(minLength: 0)
                    daylightIcon(elevation: elevation)
                }

                Text(zone)
                    .font(.system(size: 9))
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 51)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 5).fill(palette.activeTab)
                }
            }
        }
        .buttonStyle(CalendarButtonStyle(palette: palette) { inside in
            hover(on: location, inside: inside)
        })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("Focuses this city on the globe")
    }

    private func hover(on location: WorldClockLocation, inside: Bool) {
        if inside {
            hoveredCity = location.id
            previewTask?.cancel()
            previewTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 210_000_000)
                guard !Task.isCancelled, hoveredCity == location.id else { return }
                focusCity(location, false)
            }
        } else if hoveredCity == location.id {
            hoveredCity = nil
            previewTask?.cancel()
        }
    }

    private func daylightIcon(elevation: Double) -> some View {
        let symbol = elevation >= SolarPosition.sunriseElevation ? "sun.max" : elevation >= -6 ? "sun.horizon" : "moon.stars"
        let label = elevation >= SolarPosition.sunriseElevation ? "Daylight" : elevation >= -6 ? "Twilight" : "Night"
        return Image(systemName: symbol)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(elevation >= -6 ? palette.weekendText : palette.secondary)
            .accessibilityLabel(label)
    }
}
