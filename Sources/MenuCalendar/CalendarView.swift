import Combine
import SwiftUI

struct CalendarView: View {
    let showOptions: () -> Void
    let swipes: AnyPublisher<TrackpadSwipe.Direction, Never>

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pane: Pane = .calendar
    @State private var displayedMonth = Date.now
    @State private var mapLocation = WorldClockLocation.locations.first

    private let calendar = Calendar.autoupdatingCurrent
    private let weekColumnWidth: CGFloat = 22
    private let dayColumnWidth: CGFloat = 36

    private enum Pane {
        case calendar, worldClock, map
    }

    private var palette: CalendarPalette {
        colorScheme == .dark ? .dark : .light
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16)

        VStack(spacing: 8) {
            toolbar
            Group {
                switch pane {
                case .calendar:
                    TimelineView(.everyMinute) { context in
                        let month = MonthGrid(containing: displayedMonth, calendar: calendar)
                        monthView(month, today: context.date)
                    }
                case .worldClock:
                    WorldClockView(palette: palette) { location in
                        mapLocation = location
                        pane = .map
                    }
                case .map:
                    DaylightMapView(palette: palette, selected: $mapLocation)
                }
            }
            .frame(height: 221, alignment: .top)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: pane)
        }
        .padding(12)
        .frame(width: 298)
        .background(palette.surface, in: shape)
        .onReceive(swipes, perform: navigate)
        .overlay {
            shape.strokeBorder(palette.outline)
                .allowsHitTesting(false)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                tab("Calendar", symbol: "calendar", for: .calendar, help: "Swipe down from World Clock")
                tab("World Clock", symbol: "clock", for: .worldClock, help: "Swipe up from Calendar")
                tab("Map", symbol: "map", for: .map, help: "Swipe up from World Clock")
            }
            .padding(2)
            .background(palette.track, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("View")

            iconButton("ellipsis", label: "Options", action: showOptions)
        }
    }

    private func tab(_ label: String, symbol: String, for destination: Pane, help: String) -> some View {
        let isSelected = pane == destination

        return Button {
            pane = destination
        } label: {
            Label(label, systemImage: symbol)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.88)
                .foregroundStyle(isSelected ? palette.text : palette.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6).fill(palette.activeTab)
                    }
                }
        }
        .buttonStyle(CalendarButtonStyle(palette: palette))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(help)
    }

    private func monthView(_ month: MonthGrid, today: Date) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 3) {
                Text(month.title)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(palette.text)
                    .accessibilityAddTraits(.isHeader)

                Spacer(minLength: 4)

                iconButton("chevron.backward", label: "Previous month", help: "Previous month · two-finger swipe right") {
                    moveMonth(-1)
                }
                iconButton("chevron.forward", label: "Next month", help: "Next month · two-finger swipe left") {
                    moveMonth(1)
                }
            }

            dates(in: month, today: today)

            HStack {
                Button {
                    displayedMonth = .now
                } label: {
                    Text("Today")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.secondary)
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                }
                .buttonStyle(CalendarButtonStyle(palette: palette))
                .help("Return to the current month")

                Spacer()
            }
        }
    }

    private func dates(in month: MonthGrid, today: Date) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Wk")
                    .frame(width: weekColumnWidth)
                    .accessibilityLabel("Week number")

                ForEach(month.weekdayNames.indices, id: \.self) { index in
                    Text(month.weekdayNames[index])
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .foregroundStyle(month.weekendColumns.contains(index) ? palette.weekendText : palette.secondary)
                        .frame(width: dayColumnWidth)
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(palette.secondary)
            .frame(height: 19)

            ForEach(month.weeks.indices, id: \.self) { index in
                let week = month.weeks[index]
                let isCurrentWeek = week.contains { calendar.isDate($0, inSameDayAs: today) }

                HStack(spacing: 0) {
                    if let firstDay = week.first {
                        let number = calendar.component(.weekOfYear, from: firstDay)
                        Text(number, format: .number)
                            .font(.system(size: 10, weight: isCurrentWeek ? .semibold : .regular).monospacedDigit())
                            .foregroundStyle(isCurrentWeek ? palette.text : palette.secondary)
                            .frame(width: weekColumnWidth)
                            .accessibilityLabel(isCurrentWeek ? "Current week, \(number)" : "Week \(number)")
                    }
                    ForEach(week.indices, id: \.self) { dayIndex in
                        dayCell(week[dayIndex], in: month, today: today,
                                isWeekend: month.weekendColumns.contains(dayIndex))
                    }
                }
            }
        }
        .background {
            HStack(spacing: 0) {
                Color.clear.frame(width: weekColumnWidth)
                ForEach(month.weekdayNames.indices, id: \.self) { index in
                    (month.weekendColumns.contains(index) ? palette.weekendSurface : Color.clear)
                        .frame(width: dayColumnWidth)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .accessibilityHidden(true)
        }
    }

    private func dayCell(_ date: Date, in month: MonthGrid, today: Date, isWeekend: Bool) -> some View {
        let isToday = calendar.isDate(date, inSameDayAs: today)
        let isInMonth = calendar.isDate(date, equalTo: month.start, toGranularity: .month)
        let day = calendar.component(.day, from: date)
        let fullDate = date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        let dayColor = isInMonth ? (isWeekend ? palette.weekendText : palette.text) : palette.adjacent

        return Text(day, format: .number)
            .font(.system(size: 12, weight: isToday ? .semibold : .medium).monospacedDigit())
            .foregroundStyle(isToday ? Color.white : dayColor)
            .frame(width: 21, height: 21)
            .background {
                if isToday {
                    Circle().fill(palette.accent)
                }
            }
            .frame(width: dayColumnWidth, height: 24)
            .accessibilityLabel(isToday ? "Today, \(fullDate)" : fullDate)
    }

    private func iconButton(_ symbol: String, label: String, help: String? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.secondary)
                .frame(width: 25, height: 25)
        }
        .buttonStyle(CalendarButtonStyle(palette: palette))
        .accessibilityLabel(label)
        .help(help ?? label)
    }

    private func navigate(_ direction: TrackpadSwipe.Direction) {
        switch (pane, direction) {
        case (.calendar, .left):
            moveMonth(1)
        case (.calendar, .right):
            moveMonth(-1)
        case (.calendar, .up):
            pane = .worldClock
        case (.worldClock, .up):
            pane = .map
        case (.map, .down):
            pane = .worldClock
        case (.worldClock, .down):
            pane = .calendar
        default:
            break
        }
    }

    private func moveMonth(_ amount: Int) {
        if let start = calendar.dateInterval(of: .month, for: displayedMonth)?.start,
           let nextMonth = calendar.date(byAdding: .month, value: amount, to: start) {
            displayedMonth = nextMonth
        }
    }
}

struct CalendarButtonStyle: ButtonStyle {
    let palette: CalendarPalette

    func makeBody(configuration: Configuration) -> some View {
        ButtonContent(configuration: configuration, palette: palette)
    }

    private struct ButtonContent: View {
        let configuration: ButtonStyle.Configuration
        let palette: CalendarPalette
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(configuration.isPressed || isHovered ? palette.outline : Color.clear)
                }
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
        }
    }
}
