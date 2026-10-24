import Foundation

/// Rates in the pricing currency per million tokens. Cache write is billed as
/// prompt input by every provider that reports it, but each rate stays explicit
/// so a provider that discounts it can be priced correctly.
struct ModelPrice: Codable, Hashable {
    var input: Double = 0
    var output: Double = 0
    var cacheRead: Double = 0
    var cacheWrite: Double = 0

    init(input: Double = 0, output: Double = 0, cacheRead: Double = 0, cacheWrite: Double = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    /// A config file may set only the rates it knows; the rest stay at zero.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        input = try container.decodeIfPresent(Double.self, forKey: .input) ?? 0
        output = try container.decodeIfPresent(Double.self, forKey: .output) ?? 0
        cacheRead = try container.decodeIfPresent(Double.self, forKey: .cacheRead) ?? 0
        cacheWrite = try container.decodeIfPresent(Double.self, forKey: .cacheWrite) ?? 0
    }
}

/// Some providers price by time of day. DeepSeek's published table doubles
/// during `peakHoursUTC`, a list of `[startHour, endHour)` pairs.
struct PriceSchedule: Codable, Hashable {
    var peakHoursUTC: [[Int]] = []
    var peakMultiplier: Double = 1
    var weekdaysOnly: Bool = true

    init(peakHoursUTC: [[Int]] = [], peakMultiplier: Double = 1, weekdaysOnly: Bool = true) {
        self.peakHoursUTC = peakHoursUTC
        self.peakMultiplier = peakMultiplier
        self.weekdaysOnly = weekdaysOnly
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        peakHoursUTC = try container.decodeIfPresent([[Int]].self, forKey: .peakHoursUTC) ?? []
        peakMultiplier = try container.decodeIfPresent(Double.self, forKey: .peakMultiplier) ?? 1
        weekdaysOnly = try container.decodeIfPresent(Bool.self, forKey: .weekdaysOnly) ?? true
    }

    func multiplier(at date: Date) -> Double {
        guard !peakHoursUTC.isEmpty, peakMultiplier != 1 else { return 1 }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let parts = calendar.dateComponents([.hour, .weekday], from: date)
        guard let hour = parts.hour, let weekday = parts.weekday else { return 1 }
        if weekdaysOnly, weekday == 1 || weekday == 7 { return 1 }

        for window in peakHoursUTC where window.count == 2 {
            if hour >= window[0], hour < window[1] { return peakMultiplier }
        }
        return 1
    }
}

struct Pricing: Codable, Hashable {
    var currency: String = "USD"
    /// Matched by exact model id first, then by the longest key contained in the
    /// id, so `glm-4.6` prices `z-ai/glm-4.6`.
    var models: [String: ModelPrice] = [:]
    /// Used when no key matches. With no fallback, unlisted models stay unpriced
    /// instead of being silently costed at zero.
    var fallback: ModelPrice?
    var schedule: PriceSchedule?

    /// DeepSeek's off-peak USD rates as published. Verify before relying on them;
    /// providers change prices more often than this app ships a release.
    static let deepSeekModels: [String: ModelPrice] = [
        "deepseek-flash": ModelPrice(input: 0.15, output: 0.60, cacheRead: 0.003, cacheWrite: 0.15),
        "deepseek-v4-pro": ModelPrice(input: 0.66, output: 1.98, cacheRead: 0.022, cacheWrite: 0.66),
        // Older ids that still appear in transcripts.
        "deepseek-chat": ModelPrice(input: 0.15, output: 0.60, cacheRead: 0.003, cacheWrite: 0.15),
        "deepseek-reasoner": ModelPrice(input: 0.66, output: 1.98, cacheRead: 0.022, cacheWrite: 0.66),
    ]

    static let deepSeekSchedule = PriceSchedule(
        peakHoursUTC: [[1, 4], [6, 10]],
        peakMultiplier: 2
    )

    static let deepSeek = Pricing(
        currency: "USD",
        models: deepSeekModels,
        schedule: deepSeekSchedule
    )

    init(
        currency: String = "USD",
        models: [String: ModelPrice] = [:],
        fallback: ModelPrice? = nil,
        schedule: PriceSchedule? = nil
    ) {
        self.currency = currency
        self.models = models
        self.fallback = fallback
        self.schedule = schedule
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currency = try container.decodeIfPresent(String.self, forKey: .currency) ?? "USD"
        models = try container.decodeIfPresent([String: ModelPrice].self, forKey: .models) ?? [:]
        fallback = try container.decodeIfPresent(ModelPrice.self, forKey: .fallback)
        schedule = try container.decodeIfPresent(PriceSchedule.self, forKey: .schedule)
    }

    func price(for model: String) -> ModelPrice? {
        if let exact = models[model] { return exact }

        let contained = models.keys
            .filter { !$0.isEmpty && model.range(of: $0, options: .caseInsensitive) != nil }
            .max { $0.count < $1.count }
        if let contained { return models[contained] }
        return fallback
    }

    /// Cost of one response in `currency`, or nil when no rate covers the model.
    func cost(of sample: UsageSample) -> Double? {
        guard let price = price(for: sample.model) else { return nil }

        let raw = Double(sample.input) * price.input
            + Double(sample.output) * price.output
            + Double(sample.cacheRead) * price.cacheRead
            + Double(sample.cacheWrite) * price.cacheWrite

        let multiplier = schedule?.multiplier(at: sample.date) ?? 1
        return raw / 1_000_000 * multiplier
    }

    /// Config entries are merged over the preset, so a user who adds one model
    /// keeps the defaults for every other.
    mutating func merge(_ override: PricingOverride) {
        if let currency = override.currency { self.currency = currency }
        if let models = override.models {
            for (name, price) in models { self.models[name] = price }
        }
        if let fallback = override.fallback { self.fallback = fallback }
        if let schedule = override.schedule { self.schedule = schedule }
    }
}

struct PricingOverride: Codable {
    var currency: String?
    var models: [String: ModelPrice]?
    var fallback: ModelPrice?
    var schedule: PriceSchedule?
}
