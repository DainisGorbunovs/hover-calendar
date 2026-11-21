import AppKit
import Combine
import SwiftUI

struct CalendarView: View {
    let showOptions: () -> Void
    let swipes: AnyPublisher<TrackpadMotion, Never>
    let globePinch: GlobePinchInput

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pane: Pane = .calendar
    @State private var referenceDate = Date.now
    @State private var monthIndex = 0
    @State private var page = 0.0
    @State private var monthSwipe = MonthSwipe()
    @State private var mapLocation: WorldClockLocation?
    @State private var tabHover: Task<Void, Never>?
    @State private var hoveredTab: Pane?
    @State private var hoveredDay: Date?
    @State private var showingHolidayRegions = false
    @AppStorage("HolidayRegion") private var holidayRegion = HolidayRegion.localDefault

    private let calendar = Calendar.autoupdatingCurrent
    private let weekColumnWidth: CGFloat = 22
    private let dayColumnWidth: CGFloat = 36

    private var calendarWidth: CGFloat { weekColumnWidth + 7 * dayColumnWidth }

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
                        monthView(month(at: monthIndex), today: context.date)
                    }
                case .worldClock:
                    WorldClockView(palette: palette) { location in
                        mapLocation = location
                        selectPane(.map)
                    }
                case .map:
                    DaylightMapView(palette: palette, selected: $mapLocation, swipes: swipes, pinchInput: globePinch)
                }
            }
            .frame(height: 221, alignment: .top)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: pane)
        }
        .padding(12)
        .frame(width: 298)
        .background(palette.surface, in: shape)
        .onReceive(swipes, perform: pageWithTrackpad)
        .onDisappear { tabHover?.cancel() }
        .overlay(alignment: .bottomTrailing) {
            if pane == .calendar, showingHolidayRegions {
                holidayRegions
                    .padding(.trailing, 12)
                    .padding(.bottom, 35)
            }
        }
        .overlay {
            shape.strokeBorder(palette.outline)
                .allowsHitTesting(false)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                tab("Calendar", symbol: "calendar", for: .calendar)
                tab("World Clock", symbol: "clock", for: .worldClock)
                tab("Globe", symbol: "globe.americas", for: .map)
            }
            .padding(2)
            .background(palette.track, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("View")

            iconButton("ellipsis", label: "Options", action: showOptions)
        }
    }

    private func tab(_ label: String, symbol: String, for destination: Pane) -> some View {
        let isSelected = pane == destination

        return Button {
            selectPane(destination)
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
        .onHover { inside in
            if inside {
                hoveredTab = destination
                tabHover?.cancel()
                guard !isSelected else { return }
                tabHover = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 270_000_000)
                    guard !Task.isCancelled, hoveredTab == destination else { return }
                    selectPane(destination, withFeedback: false)
                }
            } else if hoveredTab == destination {
                hoveredTab = nil
                tabHover?.cancel()
            }
        }
    }

    private func monthView(_ month: MonthGrid, today: Date) -> some View {
        let holidays = holidays(in: month)
        return VStack(spacing: 6) {
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

            MonthPageStrip(position: page, width: calendarWidth) { index in
                let visible = self.month(at: index)
                dates(in: visible, today: today, holidays: index == monthIndex ? holidays : self.holidays(in: visible))
                    .accessibilityHidden(index != monthIndex)
            }

            calendarFooter(in: month, today: today, holidays: holidays)
        }
    }

    private func holidays(in month: MonthGrid) -> PublicHolidays {
        PublicHolidays(region: holidayRegion, days: month.weeks.flatMap { $0 }, timeZone: calendar.timeZone)
    }

    private func calendarFooter(in month: MonthGrid, today: Date, holidays: PublicHolidays) -> some View {
        let dates = month.weeks.flatMap { $0 }.filter {
            calendar.isDate($0, equalTo: month.start, toGranularity: .month) && !holidays.names(on: $0).isEmpty
        }
        let holiday = hoveredDay == nil
            ? dates.first(where: { $0 >= calendar.startOfDay(for: today) }) ?? dates.first
            : hoveredDay
        let year = holidays.calendar.component(.year, from: month.start)

        return HStack(spacing: 5) {
            Button {
                goToToday()
            } label: {
                Text("Today")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.secondary)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
            }
            .buttonStyle(CalendarButtonStyle(palette: palette))
            .help("Return to the current month")

            if let holiday, !holidays.names(on: holiday).isEmpty {
                let names = holidays.names(on: holiday).joined(separator: " · ")
                let label = "\(holiday.formatted(.dateTime.month(.abbreviated).day())) · \(names)"
                HStack(spacing: 4) {
                    Circle().fill(palette.holiday).frame(width: 4, height: 4)
                        .accessibilityHidden(true)
                    Text(label)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(palette.holiday)
                .accessibilityElement(children: .combine)
                .help(label)
            } else if let hoveredDay {
                Text(hoveredDay, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
            } else if holidays.coveredYears?.contains(year) != true {
                Text("Outside published holiday dates")
                    .font(.system(size: 9))
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button {
                showingHolidayRegions.toggle()
            } label: {
                HStack(spacing: 3) {
                    Text(holidayRegion.abbreviation)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 7))
                }
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(palette.secondary)
                .padding(.horizontal, 5)
                .frame(height: 20)
            }
            .buttonStyle(CalendarButtonStyle(palette: palette))
            .accessibilityLabel("Holiday calendar, \(holidayRegion.title)")
            .help("Choose a holiday calendar")
        }
    }

    private var holidayRegions: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(HolidayRegion.allCases) { region in
                Button {
                    holidayRegion = region
                    hoveredDay = nil
                    showingHolidayRegions = false
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark")
                            .opacity(holidayRegion == region ? 1 : 0)
                            .accessibilityHidden(true)
                        Text(region.title)
                        Spacer(minLength: 2)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.text)
                    .padding(.horizontal, 6)
                    .frame(width: 153, height: 22)
                }
                .buttonStyle(CalendarButtonStyle(palette: palette))
                .accessibilityAddTraits(holidayRegion == region ? .isSelected : [])
            }
        }
        .padding(4)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(palette.outline)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }

    private func dates(in month: MonthGrid, today: Date, holidays: PublicHolidays) -> some View {
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
                        let date = week[dayIndex]
                        dayCell(date, in: month, today: today,
                                isWeekend: month.weekendColumns.contains(dayIndex),
                                holidayNames: holidays.names(on: date))
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

    private func dayCell(_ date: Date, in month: MonthGrid, today: Date, isWeekend: Bool,
                         holidayNames: [String]) -> some View {
        let isToday = calendar.isDate(date, inSameDayAs: today)
        let isInMonth = calendar.isDate(date, equalTo: month.start, toGranularity: .month)
        let day = calendar.component(.day, from: date)
        let fullDate = date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        let marked = !holidayNames.isEmpty
        let hovered = hoveredDay == date && page == Double(monthIndex) && !showingHolidayRegions
        let names = holidayNames.joined(separator: ", ")
        let dateLabel = isToday ? "Today, \(fullDate)" : fullDate
        let dayColor = isInMonth ? (isWeekend ? palette.weekendText : palette.text) : palette.adjacent

        return Text(day, format: .number)
            .font(.system(size: 12, weight: isToday || marked ? .semibold : .medium).monospacedDigit())
            .foregroundStyle(isToday ? Color.white : dayColor)
            .frame(width: 21, height: 21)
            .background {
                if isToday {
                    Circle().fill(palette.accent)
                } else if hovered {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(palette.activeTab)
                }
            }
            .overlay {
                if hovered {
                    RoundedRectangle(cornerRadius: isToday ? 11 : 6)
                        .strokeBorder(marked ? palette.holiday.opacity(0.72) : palette.secondary.opacity(0.55),
                                      lineWidth: 0.65)
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: hovered ? .black.opacity(colorScheme == .dark ? 0.35 : 0.18) : .clear,
                    radius: 2, y: 1)
            .offset(y: hovered && !reduceMotion ? -1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
            .frame(width: dayColumnWidth, height: 24)
            .overlay(alignment: .bottom) {
                if marked {
                    Circle().fill(palette.holiday)
                        .frame(width: 3, height: 3)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onHover { over in
                guard page == Double(monthIndex), !showingHolidayRegions else { return }
                if over {
                    hoveredDay = date
                } else if hoveredDay == date {
                    hoveredDay = nil
                }
            }
            .accessibilityLabel(marked ? "\(dateLabel), \(names)" : dateLabel)
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

    private func selectPane(_ destination: Pane, withFeedback: Bool = true) {
        tabHover?.cancel()
        guard destination != pane else { return }
        page = Double(monthIndex)
        showingHolidayRegions = false
        hoveredDay = nil
        pane = destination
        globePinch.setActive(destination == .map)
        if withFeedback {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func month(at index: Int) -> MonthGrid {
        let reference = calendar.dateInterval(of: .month, for: referenceDate)?.start ?? referenceDate
        let date = calendar.date(byAdding: .month, value: index, to: reference) ?? reference
        return MonthGrid(containing: date, calendar: calendar)
    }

    private func pageWithTrackpad(_ motion: TrackpadMotion) {
        guard pane == .calendar, !motion.isMomentum else { return }
        let displacement = monthSwipe.preview(motion, width: calendarWidth)
        if motion.finished || motion.cancelled {
            moveMonth(monthSwipe.monthChange(for: motion))
        } else if !reduceMotion {
            page = Double(monthIndex) + displacement
        }
    }

    private func moveMonth(_ amount: Int) {
        if amount != 0 { hoveredDay = nil }
        monthIndex += amount
        withAnimation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.88)) {
            page = Double(monthIndex)
        }
        if amount != 0 {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func goToToday() {
        let today = Date.now
        if calendar.isDate(referenceDate, equalTo: today, toGranularity: .month) {
            moveMonth(-monthIndex)
        } else {
            referenceDate = today
            monthIndex = 0
            page = 0
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }
}

private struct MonthPageStrip<Content: View>: View, Animatable {
    var position: Double
    let width: CGFloat
    @ViewBuilder let content: (Int) -> Content

    var animatableData: Double {
        get { position }
        set { position = newValue }
    }

    var body: some View {
        let lower = Int(floor(position))
        let fraction = position - Double(lower)
        let visible = fraction < 0.0001 ? [lower] : [lower, lower + 1]

        ZStack {
            ForEach(visible, id: \.self) { index in
                content(index).offset(x: (Double(index) - position) * width)
            }
        }
        .frame(width: width)
        .clipped()
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
