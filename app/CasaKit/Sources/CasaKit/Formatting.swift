import Foundation

/// Text for the Clients and Status tabs. Pure functions; the clock is a parameter.
public enum Format {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    /// Binary units (1 KB = 1024 B), as the panel shows them: `0 B`, `512 B`, `1.50 GB`, `12.3 GB`, `120 GB`.
    public static func bytes(_ count: Int64) -> String {
        var value = Double(max(0, count))
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if unit == 0 { return "\(Int(value)) \(units[0])" }
        let text: String
        switch value {
        case 100...: text = String(format: "%.0f", value)
        case 10...: text = String(format: "%.1f", value)
        default: text = String(format: "%.2f", value)
        }
        return "\(text) \(units[unit])"
    }

    public static func bytes(_ count: UInt64) -> String {
        bytes(Int64(clamping: count))
    }

    /// `12.3 GB of 50 GB`, or `12.3 GB used` when there is no limit.
    public static func traffic(used: Int64, limit: Int64?) -> String {
        guard let limit, limit > 0 else { return "\(bytes(used)) used" }
        return "\(bytes(used)) of \(bytes(limit))"
    }

    /// Used share of the limit, 0 to 1; nil when there is no limit.
    public static func trafficFraction(used: Int64, limit: Int64?) -> Double? {
        guard let limit, limit > 0 else { return nil }
        return min(1, max(0, Double(used) / Double(limit)))
    }

    /// `37%`
    public static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// `12 d 3 h`, `5 h 12 min`, `3 min`, `under a minute`.
    public static func uptime(seconds: UInt64) -> String {
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days) d \(hours) h" }
        if hours > 0 { return "\(hours) h \(minutes) min" }
        if minutes > 0 { return "\(minutes) min" }
        return "under a minute"
    }
}

/// When a client expires.
public struct ExpiryInfo: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case never
        /// The countdown starts at the first connection.
        case startsOnFirstUse(days: Int)
        case active
        case expired
    }

    public var kind: Kind
    public var text: String
    /// True when the client has under 3 days left, or has expired. Matches the `client.expiring` alert.
    public var isUrgent: Bool

    /// `expiryTime` is Unix milliseconds, 0 for never, negative for "N ms after first use".
    public static func describe(expiryTime: Int64, now: Date = Date()) -> ExpiryInfo {
        if expiryTime == 0 {
            return ExpiryInfo(kind: .never, text: "No expiry", isUrgent: false)
        }
        if expiryTime < 0 {
            let days = Int((Double(-expiryTime) / 86_400_000).rounded())
            let text = days == 1 ? "Starts on first use, then 1 day" : "Starts on first use, then \(days) days"
            return ExpiryInfo(kind: .startsOnFirstUse(days: days), text: text, isUrgent: false)
        }
        let expiry = Date(timeIntervalSince1970: Double(expiryTime) / 1000)
        let remaining = expiry.timeIntervalSince(now)
        if remaining <= 0 {
            return ExpiryInfo(kind: .expired, text: "Expired \(span(-remaining)) ago", isUrgent: true)
        }
        let text = remaining < 60 ? "Expires in under a minute" : "Expires in \(span(remaining))"
        return ExpiryInfo(kind: .active, text: text, isUrgent: remaining < 3 * 86_400)
    }

    /// `3 days`, `5 hours`, `20 minutes`.
    static func span(_ seconds: TimeInterval) -> String {
        let days = Int(seconds / 86_400)
        if days >= 1 { return days == 1 ? "1 day" : "\(days) days" }
        let hours = Int(seconds / 3_600)
        if hours >= 1 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        let minutes = max(1, Int(seconds / 60))
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}
