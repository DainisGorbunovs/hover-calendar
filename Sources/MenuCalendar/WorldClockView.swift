import SwiftUI

struct WorldClockView: View {
    let palette: CalendarPalette
    let showMap: (WorldClockLocation) -> Void

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(spacing: 0) {
                ForEach(WorldClockLocation.locations) { location in
                    let reading = location.reading(at: context.date)

                    Button {
                        showMap(location)
                    } label: {
                        HStack(alignment: .center, spacing: 8) {
                            Text(location.flag)
                                .font(.system(size: 13))
                                .frame(width: 18)
                                .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(location.name)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(palette.text)
                                Text(reading.zone)
                                    .font(.system(size: 10))
                                    .foregroundStyle(palette.secondary)
                            }

                            Spacer(minLength: 8)

                            VStack(alignment: .trailing, spacing: 1) {
                                Text(reading.time)
                                    .font(.system(size: 17, weight: .medium).monospacedDigit())
                                    .foregroundStyle(palette.text)
                                Text(reading.differentDay ?? "")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(palette.secondary)
                                    .frame(height: 11)
                                    .accessibilityHidden(reading.differentDay == nil)
                            }
                        }
                        .padding(.horizontal, 5)
                        .frame(height: 36.5)
                    }
                    .buttonStyle(CalendarButtonStyle(palette: palette))
                    .overlay(alignment: .bottom) {
                        if location.id != WorldClockLocation.locations.last?.id {
                            Rectangle()
                                .fill(palette.outline)
                                .frame(height: 0.5)
                                .padding(.horizontal, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("Shows this city on the daylight map")
                    .help("Show \(location.name) on the map")
                }
            }
        }
    }
}
