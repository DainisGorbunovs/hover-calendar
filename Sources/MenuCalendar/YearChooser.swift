import SwiftUI

struct YearChooser: View {
    let calendar: Calendar
    let palette: CalendarPalette
    @Binding var selectedYear: Date
    let choose: (Date) -> Void
    let back: () -> Void
    let close: () -> Void

    var body: some View {
        let current = min(9999, max(1, calendar.component(.year, from: selectedYear)))
        let decade = current - current % 10
        let first = max(1, decade)
        let last = min(9999, decade + 9)
        let years = max(1, decade - 1)...min(9999, decade + 10)
        let shape = RoundedRectangle(cornerRadius: 8)

        VStack(spacing: 7) {
            HStack(spacing: 5) {
                control("chevron.left", label: "Back to months", action: back)
                Spacer(minLength: 0)
                control("chevron.backward", label: "Previous decade") { move(by: -10) }
                Text("\(first.formatted(.number.grouping(.never)))–\(last.formatted(.number.grouping(.never)))")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(palette.text)
                control("chevron.forward", label: "Next decade") { move(by: 10) }
                Spacer(minLength: 0)
                control("xmark", label: "Close year picker", action: close)
            }
            .foregroundStyle(palette.secondary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                ForEach(Array(years), id: \.self) { year in
                    if let date = CalendarYear.date(forYear: String(year), near: selectedYear, calendar: calendar) {
                        Button {
                            choose(date)
                        } label: {
                            Text(year, format: .number.grouping(.never))
                                .font(.system(size: 11, weight: year == current ? .semibold : .medium).monospacedDigit())
                                .foregroundStyle(year == current ? .white : (first...last).contains(year) ? palette.text : palette.secondary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 24)
                                .background(year == current ? palette.accent : palette.track,
                                            in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(CalendarButtonStyle(palette: palette))
                        .accessibilityAddTraits(year == current ? .isSelected : [])
                    }
                }
            }
        }
        .padding(7)
        .background(palette.surface, in: shape)
        .overlay { shape.strokeBorder(palette.outline, lineWidth: 0.75).allowsHitTesting(false) }
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Choose a year")
    }

    private func control(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 23, height: 23)
        }
        .buttonStyle(CalendarButtonStyle(palette: palette))
        .accessibilityLabel(label)
        .help(label)
    }

    private func move(by amount: Int) {
        if let next = calendar.date(byAdding: .year, value: amount, to: selectedYear),
           (1...9999).contains(calendar.component(.year, from: next)) {
            selectedYear = next
        }
    }
}
