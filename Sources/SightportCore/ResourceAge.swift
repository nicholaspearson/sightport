import Foundation

/// Compact elapsed time, with the next instant at which the label can change.
public struct ResourceAge {
    public let text: String
    public let nextChange: Date

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    public init(createdAt: Date, now: Date) {
        let seconds = Int(max(0, now.timeIntervalSince(createdAt)))
        let step: Int
        switch seconds {
        case ..<60:
            step = 1
            text = "\(seconds)s"
        case ..<3600:
            step = 60
            text = "\(seconds / 60)m"
        case ..<86_400:
            step = 3600
            text = "\(seconds / 3600)h"
        default:
            step = 86_400
            let days = seconds / step
            if days < 365 {
                text = "\(days)d"
            } else {
                let parts = Self.calendar.dateComponents([.year, .day], from: createdAt, to: now)
                let years = parts.year ?? 0
                let remaining = parts.day ?? 0
                text = years == 0 ? "\(days)d" : "\(years)y" + (remaining == 0 ? "" : "\(remaining)d")
            }
        }
        nextChange = createdAt.addingTimeInterval(TimeInterval((seconds / step + 1) * step))
    }
}
