import SwiftUI

struct WorldClockView: View {
    let palette: CalendarPalette

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(spacing: 0) {
                ForEach(WorldClockLocation.locations) { location in
                    let reading = location.reading(at: context.date)

                    HStack(alignment: .center, spacing: 8) {
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
                    .overlay(alignment: .bottom) {
                        if location.id != WorldClockLocation.locations.last?.id {
                            Rectangle()
                                .fill(palette.outline)
                                .frame(height: 0.5)
                                .padding(.horizontal, 5)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
