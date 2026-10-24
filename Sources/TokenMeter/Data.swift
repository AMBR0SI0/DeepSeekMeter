import Foundation
import Observation

// MARK: - One deduped API response

struct UsageSample {
    let id: String
    let date: Date
    let minuteKey: String
    let dayKey: String
    let model: String
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int

    var tokens: Int { input + output + cacheRead + cacheWrite }
}

// MARK: - Transcript scanner

enum TranscriptScanner {
    /// Claude Code's transcript directory. Override with TOKENMETER_TRANSCRIPTS.
    static var root: URL {
        let environment = ProcessInfo.processInfo.environment
        let override = environment["TOKENMETER_TRANSCRIPTS"] ?? environment["DEEPSEEKMETER_TRANSCRIPTS"]
        if let override, !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects")
    }

    static func transcriptFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            files.append(url)
        }
        return files
    }

    /// Reads only the bytes appended since the last pass. `offsets` and `seen` must
    /// persist between calls so a re-scan is cheap and no response is counted twice.
    static func scan(offsets: inout [String: UInt64], seen: inout Set<String>, ingest: (UsageSample) -> Void) {
        for url in transcriptFiles() {
            let path = url.path
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? UInt64 else { continue }

            var offset = offsets[path] ?? 0
            if size < offset { offset = 0 }
            guard size > offset else { continue }

            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }

            do { try handle.seek(toOffset: offset) } catch { continue }
            guard let data = try? handle.readToEnd(), !data.isEmpty else { continue }
            guard let text = String(data: data, encoding: .utf8) else {
                offsets[path] = size
                continue
            }

            var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            var consumed = UInt64(data.count)
            if !text.hasSuffix("\n"), let partial = lines.popLast() {
                // Leave the incomplete trailing line for the next pass.
                consumed = UInt64(data.count) - UInt64(partial.utf8.count)
            }

            for line in lines {
                if let sample = parse(line: line, seen: &seen) { ingest(sample) }
            }

            offsets[path] = offset + consumed
        }
    }

    static func parse(line: Substring, seen: inout Set<String>) -> UsageSample? {
        guard line.hasPrefix("{"),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let timestamp = object["timestamp"] as? String,
              let date = Clock.parse(timestamp) else { return nil }

        let id = (message["id"] as? String) ?? (object["uuid"] as? String) ?? ""
        guard !id.isEmpty, !seen.contains(id) else { return nil }
        seen.insert(id)

        // The CLI records the same response more than once; the id check above
        // is what keeps token totals honest.
        func int(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }

        return UsageSample(
            id: id,
            date: date,
            minuteKey: Clock.minuteKey(date),
            dayKey: Clock.dayKey(date),
            model: (message["model"] as? String) ?? "unknown",
            input: int("input_tokens"),
            output: int("output_tokens"),
            cacheRead: int("cache_read_input_tokens"),
            cacheWrite: int("cache_creation_input_tokens")
        )
    }
}

// MARK: - Store

@MainActor
@Observable
final class UsageStore {
    static let shared = UsageStore()

    /// Minute detail is kept this many days; daily summaries live much longer.
    static let detailDays = 3

    var balance = Balance()
    var minutes: [String: Int] = [:]
    var days: [String: DayRecord] = [:]
    var thresholds = Thresholds()
    var provider = Preset.deepSeek.provider
    var pricing = Preset.deepSeek.pricing
    /// Days shown in the report; 3–30, from `config.json`.
    var historyDays = 7
    var lastScan = Date.distantPast
    var problem: String?
    var isReady = false

    /// Injection point so the windows can be tested without waiting on a clock.
    var now: () -> Date = Date.init

    private var seen = Set<String>()
    private var offsets: [String: UInt64] = [:]
    private var lastBalanceTotal: Double?
    private var lastBalanceAt: Date?
    private var ticker: Task<Void, Never>?
    private var lastBalanceFetch = Date.distantPast

    nonisolated static var dataDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "TokenMeter", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    nonisolated static var configFileURL: URL {
        dataDirectory.appending(path: "config.json")
    }

    private var stateURL: URL { UsageStore.dataDirectory.appending(path: "state.json") }
    private var configURL: URL { UsageStore.configFileURL }

    // MARK: Lifecycle

    func start() {
        guard ticker == nil else { return }
        UsageStore.migrateLegacyData()
        load()
        applyConfig()
        scan()
        isReady = true
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard let self else { return }
                self.scan()
                if self.now().timeIntervalSince(self.lastBalanceFetch) > 60 {
                    await self.refreshBalance()
                }
            }
        }
        Task { await refreshBalance() }
    }

    /// Renaming the app changes the data folder. Copy the old state once so
    /// history survives; the old folder is left untouched.
    nonisolated static func migrateLegacyData() {
        let fileManager = FileManager.default
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }

        let legacy = support.appending(path: "DeepSeekMeter", directoryHint: .isDirectory)
        let current = dataDirectory
        guard !fileManager.fileExists(atPath: current.appending(path: "state.json").path),
              fileManager.fileExists(atPath: legacy.appending(path: "state.json").path) else { return }

        for name in ["state.json", "config.json"] {
            let from = legacy.appending(path: name)
            let to = current.appending(path: name)
            guard fileManager.fileExists(atPath: from.path),
                  !fileManager.fileExists(atPath: to.path) else { continue }
            try? fileManager.copyItem(at: from, to: to)
        }
    }

    // MARK: Windows

    func tokens(lastMinutes count: Int) -> Int {
        let reference = now()
        var total = 0
        for offset in 0..<count {
            guard let date = Calendar.current.date(byAdding: .minute, value: -offset, to: reference) else { continue }
            total += minutes[Clock.minuteKey(date)] ?? 0
        }
        return total
    }

    var tokens1m: Int { tokens(lastMinutes: 1) }
    var tokens10m: Int { tokens(lastMinutes: 10) }
    var tokens1h: Int { tokens(lastMinutes: 60) }

    var level1m: Level { Level(value: tokens1m, warn: thresholds.warn1m, red: thresholds.red1m) }
    var level10m: Level { Level(value: tokens10m, warn: thresholds.warn10m, red: thresholds.red10m) }
    var level1h: Level { Level(value: tokens1h, warn: thresholds.warn1h, red: thresholds.red1h) }

    var overallLevel: Level { max(level1m, max(level10m, level1h)) }

    var isQuiet: Bool { tokens10m < thresholds.idleBelow }

    /// Oldest → newest, 60 buckets of one minute.
    var sparkline: [Int] {
        let reference = now()
        return (0..<60).reversed().map { offset -> Int in
            guard let date = Calendar.current.date(byAdding: .minute, value: -offset, to: reference) else { return 0 }
            return minutes[Clock.minuteKey(date)] ?? 0
        }
    }

    func bucket(at index: Int) -> (date: Date, tokens: Int) {
        let reference = now()
        let offset = 59 - index
        let date = Calendar.current.date(byAdding: .minute, value: -offset, to: reference) ?? reference
        return (date, minutes[Clock.minuteKey(date)] ?? 0)
    }

    var maxBucket: Int { max(sparkline.max() ?? 0, 1) }

    var today: DayRecord {
        let key = Clock.dayKey(now())
        return days[key] ?? DayRecord(key: key)
    }

    /// Newest first, missing days filled in so the report keeps its shape.
    var reportDays: [DayRecord] {
        let reference = now()
        return (0..<historyDays).compactMap { offset -> DayRecord? in
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: reference) else { return nil }
            let key = Clock.dayKey(date)
            if let record = days[key] { return record }
            let startOfDay = Calendar.current.startOfDay(for: date)
            return startOfDay > reference ? nil : DayRecord(key: key)
        }
    }

    var busiestDay: Int { days.values.map(\.tokens).max() ?? 1 }

    /// True once a balance has actually been read; until then the widget falls
    /// back to today's spend, which works for providers without a balance API.
    var showsBalance: Bool { provider.balance != nil && balance.fetchedAt != .distantPast }

    /// The number in the pill and the top of the card.
    var headlineValue: Double { showsBalance ? balance.total : today.spend }

    var headlineLabel: String { showsBalance ? "left" : "spent today" }

    /// A balance carries its own currency; a spend total is priced in the
    /// table's currency and must not borrow the balance's symbol.
    var headlineCurrency: String { showsBalance ? balance.currency : pricing.currency }
    var spendCurrency: String { pricing.currency }

    // MARK: Scanning

    func scan() {
        var ingested = 0
        TranscriptScanner.scan(offsets: &offsets, seen: &seen) { sample in
            ingested += 1
            ingest(sample)
        }
        lastScan = now()
        // The ticker runs every four seconds; rewriting a multi-megabyte state
        // file on a pass that found nothing new is pure waste.
        if ingested > 0 || prune() {
            save()
        }
    }

    /// One response into the minute, day and price buckets. Internal so tests
    /// can feed a sample without writing a transcript.
    func ingest(_ sample: UsageSample) {
        minutes[sample.minuteKey, default: 0] += sample.tokens

        var record = days[sample.dayKey] ?? DayRecord(key: sample.dayKey)
        record.tokens += sample.tokens
        record.requests += 1
        record.input += sample.input
        record.output += sample.output
        record.cacheRead += sample.cacheRead
        record.cacheWrite += sample.cacheWrite
        record.models[sample.model, default: 0] += sample.tokens
        if let cost = pricing.cost(of: sample) {
            record.spend += cost
            record.pricedTokens += sample.tokens
        }
        days[sample.dayKey] = record
    }

    /// Drops expired minute detail and trims old days to a summary.
    /// Returns whether anything changed.
    @discardableResult
    private func prune() -> Bool {
        let reference = now()
        let cutoff = Calendar.current.startOfDay(
            for: Calendar.current.date(byAdding: .day, value: -UsageStore.detailDays, to: reference) ?? reference
        )
        var changed = false

        let expired = minutes.keys.filter { key in
            guard let date = Clock.date(fromMinuteKey: key) else { return true }
            return date < cutoff
        }
        if !expired.isEmpty {
            for key in expired { minutes.removeValue(forKey: key) }
            changed = true
        }

        for (key, var record) in days {
            guard let date = Clock.date(fromDayKey: key), date < cutoff else { continue }
            let trimmed = record.models
                .sorted { $0.value > $1.value }
                .prefix(3)
                .reduce(into: [:]) { $0[$1.key] = $1.value }
            guard trimmed != record.models else { continue }
            record.models = trimmed
            days[key] = record
            changed = true
        }

        // Keep a month of summaries, and never prune what the report shows.
        let keepDays = max(30, historyDays)
        let oldest = Calendar.current.date(byAdding: .day, value: -keepDays, to: reference) ?? reference
        let kept = days.filter { key, _ in
            guard let date = Clock.date(fromDayKey: key) else { return false }
            return date >= oldest
        }
        if kept.count != days.count {
            days = kept
            changed = true
        }
        return changed
    }

    // MARK: Balance

    func refreshBalance() async {
        let stamp = now()
        lastBalanceFetch = stamp

        guard provider.balance != nil else {
            balance = Balance()
            problem = nil
            return
        }
        guard let key = provider.key.resolve() else {
            problem = MeterError.noToken.localizedDescription
            return
        }

        do {
            let fresh = try await BalanceClient.fetch(provider, key: key)

            // Only attribute a delta to today when the two readings are close
            // enough that nothing unobserved happened in between — otherwise a
            // spend overnight would land on this morning's total.
            if let previous = lastBalanceTotal,
               let previousAt = lastBalanceAt,
               stamp.timeIntervalSince(previousAt) < 15 * 60,
               previous - fresh.total > 0.000_1 {
                let key = Clock.dayKey(stamp)
                var record = days[key] ?? DayRecord(key: key)
                record.observed += previous - fresh.total
                days[key] = record
            }
            // A rise means a top-up, not negative spend.
            lastBalanceTotal = fresh.total
            lastBalanceAt = stamp

            balance = fresh
            problem = nil
            save()
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: Configuration

    private struct ConfigFile: Decodable {
        var provider: ProviderOverride?
        var pricing: PricingOverride?
        var historyDays: Int?
        var thresholds: Thresholds?
    }

    /// Optional `config.json` next to `state.json`; every field is optional.
    private func applyConfig() {
        let preset = Presets.detect()
        var resolved = preset.provider
        var rates = preset.pricing
        var days = historyDays
        var configured: Thresholds?

        if let data = try? Data(contentsOf: configURL),
           let config = try? JSONDecoder().decode(ConfigFile.self, from: data) {
            resolved.merge(config.provider)
            if let override = config.pricing { rates.merge(override) }
            if let value = config.historyDays { days = min(max(value, 3), 30) }
            configured = config.thresholds
        }

        provider = resolved
        pricing = rates
        historyDays = days
        if let configured { thresholds = configured }
    }

    /// The menu's "Reload Configuration" — no relaunch needed after an edit.
    func reloadConfiguration() {
        applyConfig()
        scan()
        Task { await refreshBalance() }
    }

    // MARK: Persistence

    private struct Snapshot: Codable {
        var version: Int
        var minutes: [String: Int]
        var days: [String: DayRecord]
        var offsets: [String: UInt64]
        var seen: [String]
        var lastBalanceTotal: Double?
        var lastBalanceAt: Date?
        var thresholds: Thresholds

        init(
            version: Int,
            minutes: [String: Int],
            days: [String: DayRecord],
            offsets: [String: UInt64],
            seen: [String],
            lastBalanceTotal: Double?,
            lastBalanceAt: Date?,
            thresholds: Thresholds
        ) {
            self.version = version
            self.minutes = minutes
            self.days = days
            self.offsets = offsets
            self.seen = seen
            self.lastBalanceTotal = lastBalanceTotal
            self.lastBalanceAt = lastBalanceAt
            self.thresholds = thresholds
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            minutes = try container.decodeIfPresent([String: Int].self, forKey: .minutes) ?? [:]
            days = try container.decodeIfPresent([String: DayRecord].self, forKey: .days) ?? [:]
            offsets = try container.decodeIfPresent([String: UInt64].self, forKey: .offsets) ?? [:]
            seen = try container.decodeIfPresent([String].self, forKey: .seen) ?? []
            lastBalanceTotal = try container.decodeIfPresent(Double.self, forKey: .lastBalanceTotal)
            lastBalanceAt = try container.decodeIfPresent(Date.self, forKey: .lastBalanceAt)
            thresholds = try container.decodeIfPresent(Thresholds.self, forKey: .thresholds) ?? Thresholds()
        }
    }

    private func save() {
        let snapshot = Snapshot(
            version: 2,
            minutes: minutes,
            days: days,
            offsets: offsets,
            seen: Array(seen),
            lastBalanceTotal: lastBalanceTotal,
            lastBalanceAt: lastBalanceAt,
            thresholds: thresholds
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: stateURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        minutes = snapshot.minutes
        days = snapshot.days
        offsets = snapshot.offsets
        seen = Set(snapshot.seen)
        lastBalanceTotal = snapshot.lastBalanceTotal
        lastBalanceAt = snapshot.lastBalanceAt
        thresholds = snapshot.thresholds

        // Version 1 only had balance-observed spend in `spend`. Move it so new
        // price-based totals start clean instead of double counting.
        if snapshot.version < 2 {
            for (key, var record) in days where record.observed == 0 {
                record.observed = record.spend
                record.spend = 0
                record.pricedTokens = 0
                days[key] = record
            }
        }
    }
}
