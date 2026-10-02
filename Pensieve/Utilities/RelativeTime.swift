import Foundation

enum RelativeTime {
    static func string(for date: Date, relativeTo now: Date) -> String {
        guard abs(now.timeIntervalSince(date)) >= 60 else { return "Just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// The sidebar's short form: "Just now", "12m ago", "3h ago", "2d ago", "3w ago", then a short
    /// date ("Jul 3") past eight weeks. Whole units, floor-rounded; a future date reads "Just now".
    static func compact(for date: Date, relativeTo now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 60 else { return "Just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        if days < 7 { return "\(days)d ago" }
        let weeks = days / 7
        if weeks < 8 { return "\(weeks)w ago" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
