import Foundation
import Observation

// MARK: - One deduped API response

struct UsageSample {
    let id: String
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
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects")
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

    private static func parse(line: Substring, seen: inout Set<String>) -> UsageSample? {
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

// MARK: - DeepSeek balance

enum DeepSeek {
    /// Read at call time from the CLI settings; never logged, never stored.
    static func token() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/settings.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = root["env"] as? [String: Any],
              let token = env["ANTHROPIC_AUTH_TOKEN"] as? String,
              !token.isEmpty else { return nil }
        return token
    }

    static func balance(token: String) async throws -> Balance {
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MeterError.badResponse }
        guard http.statusCode == 200 else { throw MeterError.status(http.statusCode) }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let infos = root["balance_infos"] as? [[String: Any]],
              let first = infos.first else { throw MeterError.badResponse }

        func number(_ key: String) -> Double {
            if let d = first[key] as? NSNumber { return d.doubleValue }
            if let s = first[key] as? String { return Double(s) ?? 0 }
            return 0
        }

        return Balance(
            total: number("total_balance"),
            granted: number("granted_balance"),
            toppedUp: number("topped_up_balance"),
            currency: (first["currency"] as? String) ?? "USD",
            fetchedAt: .now
        )
    }
}

enum MeterError: LocalizedError {
    case badResponse
    case status(Int)
    case noToken

    var errorDescription: String? {
        switch self {
        case .badResponse: return "Unexpected balance response"
        case .status(let code): return "Balance API returned \(code)"
        case .noToken: return "No ANTHROPIC_AUTH_TOKEN in settings"
        }
    }
}

// MARK: - Store

@MainActor
@Observable
final class UsageStore {
    static let shared = UsageStore()

    /// Detail is kept this many days; older days collapse to a retained summary.
    static let detailDays = 3

    var balance = Balance()
    var minutes: [String: Int] = [:]
    var days: [String: DayRecord] = [:]
    var thresholds = Thresholds()
    var lastScan = Date.distantPast
    var problem: String?
    var isReady = false

    private var seen = Set<String>()
    private var offsets: [String: UInt64] = [:]
    private var lastBalanceTotal: Double?
    private var ticker: Task<Void, Never>?
    private var lastBalanceFetch = Date.distantPast

    private var stateURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "DeepSeekMeter", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appending(path: "state.json")
    }

    // MARK: Lifecycle

    func start() {
        guard ticker == nil else { return }
        load()
        scan()
        isReady = true
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard let self else { return }
                self.scan()
                if Date.now.timeIntervalSince(self.lastBalanceFetch) > 60 {
                    await self.refreshBalance()
                }
            }
        }
        Task { await refreshBalance() }
    }

    // MARK: Windows

    func tokens(lastMinutes count: Int) -> Int {
        let now = Date.now
        var total = 0
        for offset in 0..<count {
            guard let date = Calendar.current.date(byAdding: .minute, value: -offset, to: now) else { continue }
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
        let now = Date.now
        return (0..<60).reversed().map { offset -> Int in
            guard let date = Calendar.current.date(byAdding: .minute, value: -offset, to: now) else { return 0 }
            return minutes[Clock.minuteKey(date)] ?? 0
        }
    }

    func bucket(at index: Int) -> (date: Date, tokens: Int) {
        let offset = 59 - index
        let date = Calendar.current.date(byAdding: .minute, value: -offset, to: .now) ?? .now
        return (date, minutes[Clock.minuteKey(date)] ?? 0)
    }

    var maxBucket: Int { max(sparkline.max() ?? 0, 1) }

    var today: DayRecord {
        let key = Clock.dayKey(.now)
        return days[key] ?? DayRecord(key: key)
    }

    /// Newest first, missing days filled in so the report always shows three rows.
    var reportDays: [DayRecord] {
        (0..<max(3, UsageStore.detailDays)).compactMap { offset -> DayRecord? in
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: .now) else { return nil }
            let key = Clock.dayKey(date)
            if let record = days[key] { return record }
            let startOfDay = Calendar.current.startOfDay(for: date)
            return startOfDay > .now ? nil : DayRecord(key: key)
        }
    }

    var busiestDay: Int { days.values.map(\.tokens).max() ?? 1 }

    // MARK: Scanning

    func scan() {
        TranscriptScanner.scan(offsets: &offsets, seen: &seen) { sample in
            minutes[sample.minuteKey, default: 0] += sample.tokens

            var record = days[sample.dayKey] ?? DayRecord(key: sample.dayKey)
            record.tokens += sample.tokens
            record.requests += 1
            record.input += sample.input
            record.output += sample.output
            record.cacheRead += sample.cacheRead
            record.cacheWrite += sample.cacheWrite
            record.models[sample.model, default: 0] += sample.tokens
            days[sample.dayKey] = record
        }
        lastScan = .now
        prune()
        save()
    }

    private func prune() {
        let cutoff = Calendar.current.startOfDay(
            for: Calendar.current.date(byAdding: .day, value: -UsageStore.detailDays, to: .now) ?? .now
        )
        let expired = minutes.keys.filter { key in
            guard let date = Clock.date(fromMinuteKey: key) else { return true }
            return date < cutoff
        }
        guard !expired.isEmpty else { return }
        for key in expired { minutes.removeValue(forKey: key) }

        for (key, var record) in days {
            guard let date = Clock.date(fromDayKey: key), date < cutoff else { continue }
            record.summarized = true
            record.models = record.models
                .sorted { $0.value > $1.value }
                .prefix(3)
                .reduce(into: [:]) { $0[$1.key] = $1.value }
            days[key] = record
        }
        // Keep the retention promise: a month of summaries, nothing more.
        let oldest = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
        days = days.filter { key, _ in
            guard let date = Clock.date(fromDayKey: key) else { return false }
            return date >= oldest
        }
    }

    // MARK: Balance

    func refreshBalance() async {
        lastBalanceFetch = .now
        guard let token = DeepSeek.token() else {
            problem = MeterError.noToken.localizedDescription
            return
        }
        do {
            let fresh = try await DeepSeek.balance(token: token)

            if let previous = lastBalanceTotal, previous - fresh.total > 0.000_1 {
                let key = Clock.dayKey(.now)
                var record = days[key] ?? DayRecord(key: key)
                record.spend += previous - fresh.total
                days[key] = record
            }
            // A rise means a top-up, not negative spend.
            lastBalanceTotal = fresh.total

            balance = fresh
            problem = nil
            save()
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: Persistence

    private struct Snapshot: Codable {
        var minutes: [String: Int]
        var days: [String: DayRecord]
        var offsets: [String: UInt64]
        var seen: [String]
        var lastBalanceTotal: Double?
        var thresholds: Thresholds
    }

    private func save() {
        let snapshot = Snapshot(
            minutes: minutes,
            days: days,
            offsets: offsets,
            seen: Array(seen),
            lastBalanceTotal: lastBalanceTotal,
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
        thresholds = snapshot.thresholds
    }
}
