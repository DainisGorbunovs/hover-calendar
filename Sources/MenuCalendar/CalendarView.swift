import SwiftUI

struct CalendarView: View {
    let showOptions: () -> Void

    @State private var displayedMonth = Date.now
    private let calendar = Calendar.autoupdatingCurrent

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let month = MonthGrid(containing: displayedMonth, calendar: calendar)
            VStack(spacing: 11) {
                header(for: month)
                dates(in: month, today: context.date)
                Divider()
                footer
            }
            .padding(14)
            .frame(width: 330)
        }
        .background {
            PopoverMaterial()
        }
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .strokeBorder(.primary.opacity(0.10), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private func header(for month: MonthGrid) -> some View {
        HStack(spacing: 4) {
            Text(month.title)
                .font(.system(size: 20, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            iconButton("chevron.backward", label: "Previous month") {
                moveMonth(-1, from: month.start)
            }
            iconButton("chevron.forward", label: "Next month") {
                moveMonth(1, from: month.start)
            }
        }
    }

    private func dates(in month: MonthGrid, today: Date) -> some View {
        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            GridRow {
                Text("Wk")
                    .frame(width: 26)
                    .accessibilityLabel("Week number")
                ForEach(month.weekdayNames.indices, id: \.self) { index in
                    Text(month.weekdayNames[index])
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: 35)
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)

            ForEach(month.weeks.indices, id: \.self) { index in
                let week = month.weeks[index]
                GridRow {
                    if let firstDay = week.first {
                        let number = calendar.component(.weekOfYear, from: firstDay)
                        Text(number, format: .number)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 26)
                            .accessibilityLabel("Week \(number)")
                    }
                    ForEach(week, id: \.self) { date in
                        dayCell(date, in: month, today: today)
                    }
                }
            }
        }
    }

    private func dayCell(_ date: Date, in month: MonthGrid, today: Date) -> some View {
        let isToday = calendar.isDate(date, inSameDayAs: today)
        let isInMonth = calendar.isDate(date, equalTo: month.start, toGranularity: .month)
        let day = calendar.component(.day, from: date)
        let fullDate = date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())

        return ZStack {
            if isToday {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 29, height: 29)
            }
            Text(day, format: .number)
                .font(.system(size: 13, weight: isToday ? .bold : .medium).monospacedDigit())
                .foregroundStyle(isToday ? Color.white : isInMonth ? Color.primary : Color.secondary)
        }
        .frame(width: 35, height: 30)
        .accessibilityLabel(isToday ? "Today, \(fullDate)" : fullDate)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button("Today") { displayedMonth = .now }
            Spacer()
            iconButton("ellipsis", label: "Options", action: showOptions)
        }
        .controlSize(.small)
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 25, height: 25)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle)
        .controlSize(.small)
        .accessibilityLabel(label)
        .help(label)
    }

    private func moveMonth(_ amount: Int, from start: Date) {
        if let nextMonth = calendar.date(byAdding: .month, value: amount, to: start) {
            displayedMonth = nextMonth
        }
    }
}

private struct PopoverMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
