import Foundation

// MARK: - Values

struct Balance: Codable, Hashable {
    var total: Double = 0
    var granted: Double = 0
    var toppedUp: Double = 0
    var currency: String = "USD"
    var fetchedAt: Date = .distantPast
}

struct DayRecord: Codable, Hashable, Identifiable {
    var id: String { key }
    var key: String
    var tokens: Int = 0
    var requests: Int = 0
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheWrite: Int = 0
    var spend: Double = 0
    var models: [String: Int] = [:]

    var cacheHitRate: Double {
        let prompt = input + cacheRead + cacheWrite
        return prompt > 0 ? Double(cacheRead) / Double(prompt) : 0
    }
}

struct Thresholds: Codable {
    var warn1m = 500_000
    var red1m = 1_000_000
    var warn10m = 3_000_000
    var red10m = 6_000_000
    var warn1h = 10_000_000
    var red1h = 20_000_000
    /// Below this in the ten-minute window the meter reads as quiet, not busy.
    var idleBelow = 50_000

    init() {}

    /// Hand-written so a config file can set one threshold and leave the rest
    /// at their defaults.
    init(from decoder: Decoder) throws {
        let defaults = Thresholds()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        warn1m = try container.decodeIfPresent(Int.self, forKey: .warn1m) ?? defaults.warn1m
        red1m = try container.decodeIfPresent(Int.self, forKey: .red1m) ?? defaults.red1m
        warn10m = try container.decodeIfPresent(Int.self, forKey: .warn10m) ?? defaults.warn10m
        red10m = try container.decodeIfPresent(Int.self, forKey: .red10m) ?? defaults.red10m
        warn1h = try container.decodeIfPresent(Int.self, forKey: .warn1h) ?? defaults.warn1h
        red1h = try container.decodeIfPresent(Int.self, forKey: .red1h) ?? defaults.red1h
        idleBelow = try container.decodeIfPresent(Int.self, forKey: .idleBelow) ?? defaults.idleBelow
    }
}

/// How much of the widget is showing. A click opens the compact card, its
/// expand button pins the full report open.
enum WidgetState: Equatable {
    case idle, compact, expanded
}

enum Level: Int, Comparable {
    case idle, calm, warn, hot

    static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

    init(value: Int, warn: Int, red: Int) {
        if value >= red { self = .hot }
        else if value >= warn { self = .warn }
        else if value > 0 { self = .calm }
        else { self = .idle }
    }
}

// MARK: - Clock

enum Clock {
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let minuteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func dayKey(_ date: Date) -> String { dayFormatter.string(from: date) }
    static func minuteKey(_ date: Date) -> String { minuteFormatter.string(from: date) }

    static func date(fromMinuteKey key: String) -> Date? { minuteFormatter.date(from: key) }
    static func date(fromDayKey key: String) -> Date? { dayFormatter.date(from: key) }

    static func parse(_ string: String) -> Date? {
        iso.date(from: string) ?? isoNoFraction.date(from: string)
    }
}

// MARK: - Formatting

enum Fmt {
    static func compact(_ value: Int) -> String {
        let n = Double(value)
        // The thresholds sit just below each boundary so rounding never
        // produces "1000.0k" instead of "1.00M".
        if abs(n) >= 999_950 { return String(format: "%.2fM", n / 1_000_000) }
        if abs(n) >= 999.5 { return String(format: "%.1fk", n / 1_000) }
        return String(value)
    }

    static func money(_ value: Double, currency: String) -> String {
        let symbol = currency.uppercased() == "CNY" ? "¥" : "$"
        return symbol + String(format: "%.2f", value)
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    static func relative(_ date: Date) -> String {
        guard date != .distantPast else { return "never" }
        let seconds = Date.now.timeIntervalSince(date)
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(Int(seconds))s ago" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m ago" }
        return "\(Int(seconds / 3_600))h ago"
    }

    static func weekday(_ key: String) -> String {
        guard let date = Clock.date(fromDayKey: key) else { return key }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f.string(from: date)
    }
}
