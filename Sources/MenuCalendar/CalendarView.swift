import AppKit
import Combine
import SwiftUI

struct CalendarView: View {
    let showOptions: (GlobeMenu) -> Void
    let calendarSwipes: AnyPublisher<TrackpadMotion, Never>
    let globeSwipes: AnyPublisher<TrackpadMotion, Never>
    let input: PopupInput
    let location: LocalGlobeLocation

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var referenceDate = Date.now
    @State private var monthIndex = 0
    @State private var page = 0.0
    @State private var monthSwipe = MonthSwipe()
    @State private var mapLocation: WorldClockLocation?
    @State private var cityFocus = PassthroughSubject<GlobeFocusRequest, Never>()
    @State private var hoveredDay: Date?
    @State private var selectedDay: Date?
    @State private var calendarDetail = CalendarDetail.days
    @State private var chooserYear = Date.now
    @State private var pinchPreview: CGFloat = 1
    @State private var pinchAnchor = UnitPoint.center
    @State private var calendarRevision = 0
    @State private var showingHolidayRegions = false
    @AppStorage("HolidayRegion") private var holidayRegion = HolidayRegion.localDefault

    private let calendar = Calendar.autoupdatingCurrent
    private let weekColumnWidth: CGFloat = 22
    private let dayColumnWidth: CGFloat = 36

    private var calendarWidth: CGFloat { weekColumnWidth + 7 * dayColumnWidth }
    private var showingMonthChooser: Bool { calendarDetail != .days }

    private var palette: CalendarPalette {
        colorScheme == .dark ? .dark : .light
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10)

        VStack(spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                DaylightMapView(palette: palette, selected: $mapLocation, swipes: globeSwipes,
                                input: input, location: location, focusRequests: cityFocus.eraseToAnyPublisher(), showOptions: showOptions)
                    .frame(width: 270)

                TimelineView(.everyMinute) { context in
                    monthView(month(at: monthIndex), today: context.date)
                }
                .frame(width: calendarWidth, height: 221, alignment: .top)
                .overlay {
                    if showingMonthChooser {
                        Button(action: closeMonthChooser) {
                            Rectangle().fill(palette.surface.opacity(0.78))
                        }
                        .buttonStyle(.plain)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if showingMonthChooser {
                        chooser
                            .padding(3)
                            .id(calendarDetail)
                            .transition(reduceMotion ? .identity : .scale(scale: 0.94, anchor: .topLeading).combined(with: .opacity))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if showingHolidayRegions {
                        holidayRegions.padding(.bottom, 25)
                    }
                }
                .scaleEffect(pinchPreview, anchor: pinchAnchor)
                .clipped()
                .background {
                    PopupSurface(input: input, kind: .calendar)
                        .allowsHitTesting(false)
                }
            }

            WorldClockView(palette: palette, selectedCity: mapLocation?.id) { location, tactile in
                cityFocus.send(GlobeFocusRequest(city: location, tactile: tactile))
            }
        }
        .padding(7)
        .frame(width: 566)
        .background(palette.surface, in: shape)
        .overlay { shape.strokeBorder(palette.outline, lineWidth: 0.75).allowsHitTesting(false) }
        .onReceive(calendarSwipes, perform: pageWithTrackpad)
        .onReceive(input.calendarPinches, perform: pinchCalendar)
    }

    @ViewBuilder
    private var chooser: some View {
        switch calendarDetail {
        case .days:
            EmptyView()
        case .months:
            MonthChooser(calendar: calendar, palette: palette, visibleMonth: month(at: monthIndex).start,
                         yearReference: $chooserYear, choose: { jump(to: $0) },
                         showYears: { changeCalendarDetail(to: .years) }, close: closeMonthChooser)
        case .years:
            YearChooser(calendar: calendar, palette: palette, selectedYear: $chooserYear,
                        choose: { date in
                            chooserYear = date
                            changeCalendarDetail(to: .months)
                        },
                        back: { changeCalendarDetail(to: .months) }, close: closeMonthChooser)
        }
    }

    private func monthView(_ month: MonthGrid, today: Date) -> some View {
        let holidays = holidays(in: month)
        return VStack(spacing: 6) {
            HStack(spacing: 3) {
                Button {
                    input.focusCalendarControls()
                    changeCalendarDetail(to: .months)
                } label: {
                    HStack(spacing: 5) {
                        Text(month.title)
                            .font(.system(size: 16, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .foregroundStyle(palette.text)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(palette.secondary)
                    }
                    .frame(height: 25)
                }
                .buttonStyle(CalendarButtonStyle(palette: palette))
                .accessibilityLabel("\(month.title), choose month and year")
                .help("Jump to a month and year")

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
            .id(calendarRevision)
            .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 4)))

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
        let inspectedDay = hoveredDay ?? selectedDay
        let holiday = inspectedDay == nil
            ? dates.first(where: { $0 >= calendar.startOfDay(for: today) }) ?? dates.first
            : inspectedDay
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
            } else if let inspectedDay {
                Text(inspectedDay, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
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
                calendarDetail = .days
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
        let hovered = hoveredDay == date && page == Double(monthIndex) && !showingHolidayRegions && !showingMonthChooser
        let selected = selectedDay == date
        let names = holidayNames.joined(separator: ", ")
        let dateLabel = isToday ? "Today, \(fullDate)" : fullDate
        let dayColor = isInMonth ? (isWeekend ? palette.weekendText : palette.text) : palette.adjacent

        return Button {
            if isInMonth {
                withAnimation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.72)) {
                    selectedDay = date
                }
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            } else {
                jump(to: date, selecting: date)
            }
        } label: {
            Text(day, format: .number)
                .font(.system(size: 12, weight: isToday || marked ? .semibold : .medium).monospacedDigit())
                .foregroundStyle(isToday ? Color.white : dayColor)
                .frame(width: 21, height: 21)
                .background {
                    if isToday {
                        Circle().fill(palette.accent)
                    } else if hovered || selected {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(palette.activeTab)
                    }
                }
                .overlay {
                    if hovered || selected {
                        RoundedRectangle(cornerRadius: isToday ? 11 : 6)
                            .strokeBorder(selected ? palette.accent : marked ? palette.holiday.opacity(0.72) : palette.secondary.opacity(0.55),
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
                    guard page == Double(monthIndex), !showingHolidayRegions, !showingMonthChooser else { return }
                    if over {
                        hoveredDay = date
                    } else if hoveredDay == date {
                        hoveredDay = nil
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(marked ? "\(dateLabel), \(names)" : dateLabel)
        .accessibilityAddTraits(selected ? .isSelected : [])
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

    private func month(at index: Int) -> MonthGrid {
        let reference = calendar.dateInterval(of: .month, for: referenceDate)?.start ?? referenceDate
        let date = calendar.date(byAdding: .month, value: index, to: reference) ?? reference
        return MonthGrid(containing: date, calendar: calendar)
    }

    private func pageWithTrackpad(_ motion: TrackpadMotion) {
        guard !motion.isMomentum, !showingMonthChooser else { return }
        let displacement = monthSwipe.preview(motion, width: calendarWidth)
        if motion.finished || motion.cancelled {
            moveMonth(monthSwipe.monthChange(for: motion))
        } else if !reduceMotion {
            page = Double(monthIndex) + displacement
        }
    }

    private func moveMonth(_ amount: Int) {
        if amount != 0 {
            hoveredDay = nil
            selectedDay = nil
        }
        monthIndex += amount
        withAnimation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.88)) {
            page = Double(monthIndex)
        }
        if amount != 0 {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func pinchCalendar(_ event: PopupPinch) {
        if event.phase.contains(.cancelled) {
            resetPinchPreview()
            return
        }
        if event.phase.contains(.ended) {
            let next = calendarDetail.afterPinch(scale: event.scale)
            if next != calendarDetail {
                changeCalendarDetail(to: next)
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            } else {
                resetPinchPreview()
            }
        } else if !reduceMotion, event.size.width > 0, event.size.height > 0 {
            pinchAnchor = UnitPoint(x: event.anchor.x / event.size.width, y: event.anchor.y / event.size.height)
            pinchPreview = min(1.09, max(0.91, 1 + (event.scale - 1) * 0.38))
        }
    }

    private func resetPinchPreview() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.84)) {
            pinchPreview = 1
        }
    }

    private func changeCalendarDetail(to detail: CalendarDetail) {
        if calendarDetail == .days {
            chooserYear = month(at: monthIndex).start
        }
        hoveredDay = nil
        showingHolidayRegions = false
        withAnimation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.84)) {
            pinchPreview = 1
            calendarDetail = detail
        }
    }

    private func closeMonthChooser() {
        changeCalendarDetail(to: .days)
    }

    private func jump(to date: Date, selecting selection: Date? = nil) {
        hoveredDay = nil
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.24)) {
            referenceDate = date
            monthIndex = 0
            page = 0
            selectedDay = selection
            calendarDetail = .days
            calendarRevision += 1
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private func goToToday() {
        jump(to: .now)
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
    var hover: ((Bool) -> Void)? = nil

    func makeBody(configuration: Configuration) -> some View {
        ButtonContent(configuration: configuration, palette: palette, hover: hover)
    }

    private struct ButtonContent: View {
        let configuration: ButtonStyle.Configuration
        let palette: CalendarPalette
        let hover: ((Bool) -> Void)?
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(configuration.isPressed || isHovered ? palette.outline : Color.clear)
                }
                .contentShape(Rectangle())
                .onHover { inside in
                    isHovered = inside
                    hover?(inside)
                }
        }
    }
}
