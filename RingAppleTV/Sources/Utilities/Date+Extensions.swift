import Foundation

extension Date {

    /// Formats the date for display, e.g. "Jan 15, 2026 10:30 AM".
    func formatted() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy h:mm a"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: self)
    }

    /// Returns a human-readable relative time string, e.g. "5 minutes ago",
    /// "2 hours ago", "Yesterday", etc.
    func relativeTime() -> String {
        let now = Date()
        let interval = now.timeIntervalSince(self)

        // Future dates
        if interval < 0 {
            return "Just now"
        }

        let seconds = Int(interval)
        let minutes = seconds / 60
        let hours = minutes / 60
        let days = hours / 24

        switch seconds {
        case 0..<60:
            return "Just now"
        case 60..<3600:
            return minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago"
        case 3600..<86400:
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        case 86400..<172800:
            return "Yesterday"
        default:
            return days == 1 ? "1 day ago" : "\(days) days ago"
        }
    }
}
