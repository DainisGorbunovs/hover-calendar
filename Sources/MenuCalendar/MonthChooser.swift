import AppKit
import SwiftUI

struct MonthChooser: View {
    let calendar: Calendar
    let palette: CalendarPalette
    let visibleMonth: Date
    let choose: (Date) -> Void
    let showYears: () -> Void
    let close: () -> Void

    @Binding var yearReference: Date
    @State private var yearText: String
    @FocusState private var editingYear: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(calendar: Calendar, palette: CalendarPalette, visibleMonth: Date, yearReference: Binding<Date>,
         choose: @escaping (Date) -> Void, showYears: @escaping () -> Void, close: @escaping () -> Void) {
        self.calendar = calendar
        self.palette = palette
        self.visibleMonth = visibleMonth
        self.choose = choose
        self.showYears = showYears
        self.close = close
        _yearReference = yearReference
        _yearText = State(initialValue: String(calendar.component(.year, from: yearReference.wrappedValue)))
    }

    var body: some View {
        let target = CalendarYear.date(forYear: yearText, near: yearReference, calendar: calendar)
        let year = CalendarYear(containing: target ?? yearReference, calendar: calendar)
        let bounds = RoundedRectangle(cornerRadius: 8)

        VStack(spacing: 7) {
            HStack(spacing: 5) {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 23, height: 23)
                }
                .buttonStyle(CalendarButtonStyle(palette: palette))
                .accessibilityLabel("Close month picker")

                Spacer(minLength: 0)
                yearButton("chevron.backward", label: "Previous year", step: -1)
                TextField("Year", text: $yearText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(target == nil ? palette.weekendText : palette.text)
                    .frame(width: 60, height: 24)
                    .background(palette.track, in: RoundedRectangle(cornerRadius: 5))
                    .focused($editingYear)
                    .onChange(of: editingYear) { editing in
                        guard editing else { return }
                        DispatchQueue.main.async {
                            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor {
                                editor.selectAll(nil)
                            }
                        }
                    }
                    .accessibilityLabel("Year")
                    .help("Type a year, then choose a month")
                    .onChange(of: yearText) { value in
                        if let next = CalendarYear.date(forYear: value, near: yearReference, calendar: calendar) {
                            yearReference = next
                        }
                    }
                    .onSubmit {
                        if let target { setYear(target) }
                        editingYear = false
                    }
                yearButton("chevron.forward", label: "Next year", step: 1)
                Spacer(minLength: 0)
                Button(action: showYears) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 23, height: 23)
                }
                .buttonStyle(CalendarButtonStyle(palette: palette))
                .accessibilityLabel("Browse years")
                .help("Browse years · pinch together")
            }
            .foregroundStyle(palette.secondary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                ForEach(year?.months ?? [], id: \.self) { month in
                    monthButton(month)
                }
            }
            .disabled(target == nil)
            .opacity(target == nil ? 0.55 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: year?.months)

            if target == nil {
                Text("Enter a year from 1 to 9999")
                    .font(.system(size: 9))
                    .foregroundStyle(palette.secondary)
            }
        }
        .padding(7)
        .background(palette.surface, in: bounds)
        .overlay { bounds.strokeBorder(palette.outline, lineWidth: 0.75).allowsHitTesting(false) }
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Choose a month and year")
    }

    private func monthButton(_ date: Date) -> some View {
        let selected = calendar.isDate(date, equalTo: visibleMonth, toGranularity: .month)
        let format = Date.FormatStyle(locale: calendar.locale ?? .autoupdatingCurrent,
                                      calendar: calendar, timeZone: calendar.timeZone)
            .month(.abbreviated)

        return Button {
            choose(date)
        } label: {
            Text(date, format: format)
                .font(.system(size: 11, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? .white : palette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(selected ? palette.accent : palette.track, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(CalendarButtonStyle(palette: palette))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func yearButton(_ symbol: String, label: String, step: Int) -> some View {
        Button {
            let current = CalendarYear.date(forYear: yearText, near: yearReference, calendar: calendar) ?? yearReference
            if let next = calendar.date(byAdding: .year, value: step, to: current),
               (1...9999).contains(calendar.component(.year, from: next)) {
                setYear(next)
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(CalendarButtonStyle(palette: palette))
        .accessibilityLabel(label)
        .help(label)
    }

    private func setYear(_ date: Date) {
        yearReference = date
        yearText = String(calendar.component(.year, from: date))
    }
}
