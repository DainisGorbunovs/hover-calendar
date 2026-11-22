import Foundation

enum CalendarDetail {
    case days, months, years

    func afterPinch(scale: Double) -> Self {
        if scale < 0.83 {
            switch self {
            case .days: return .months
            case .months, .years: return .years
            }
        }
        if scale > 1.18 {
            switch self {
            case .years: return .months
            case .months, .days: return .days
            }
        }
        return self
    }
}
