import XCTest
@testable import TokenMeter

final class FormattingTests: XCTestCase {
    func testCompactTokenCounts() {
        XCTAssertEqual(Fmt.compact(0), "0")
        XCTAssertEqual(Fmt.compact(999), "999")
        XCTAssertEqual(Fmt.compact(1_000), "1.0k")
        XCTAssertEqual(Fmt.compact(1_540), "1.5k")
        XCTAssertEqual(Fmt.compact(999_949), "999.9k")
        XCTAssertEqual(Fmt.compact(999_950), "1.00M")
        XCTAssertEqual(Fmt.compact(1_000_000), "1.00M")
        XCTAssertEqual(Fmt.compact(101_240_000), "101.24M")
    }

    func testMoneySymbols() {
        XCTAssertEqual(Fmt.money(20.247, currency: "USD"), "$20.25")
        XCTAssertEqual(Fmt.money(20.247, currency: "CNY"), "¥20.25")
        XCTAssertEqual(Fmt.money(0, currency: "USD"), "$0.00")
    }

    func testPercent() {
        XCTAssertEqual(Fmt.percent(0), "0%")
        XCTAssertEqual(Fmt.percent(0.96), "96%")
        XCTAssertEqual(Fmt.percent(1), "100%")
    }

    func testRelativeText() {
        let now = Date()
        XCTAssertEqual(Fmt.relative(.distantPast), "never")
        XCTAssertEqual(Fmt.relative(now), "just now")
        XCTAssertEqual(Fmt.relative(now.addingTimeInterval(-42)), "42s ago")
        XCTAssertEqual(Fmt.relative(now.addingTimeInterval(-61)), "1m ago")
        XCTAssertEqual(Fmt.relative(now.addingTimeInterval(-7_200)), "2h ago")
    }
}

final class ClockTests: XCTestCase {
    func testDayKeyRoundTrips() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let key = Clock.dayKey(date)
        let parsed = try XCTUnwrap(Clock.date(fromDayKey: key))
        XCTAssertEqual(Clock.dayKey(parsed), key)
    }

    func testMinuteKeyRoundTrips() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let key = Clock.minuteKey(date)
        let parsed = try XCTUnwrap(Clock.date(fromMinuteKey: key))
        XCTAssertEqual(Clock.minuteKey(parsed), key)
    }

    func testParsesFractionalAndPlainTimestamps() {
        XCTAssertNotNil(Clock.parse("2026-10-22T09:14:03.123Z"))
        XCTAssertNotNil(Clock.parse("2026-10-22T09:14:03Z"))
        XCTAssertNil(Clock.parse("yesterday"))
    }
}

final class LevelTests: XCTestCase {
    func testBoundaries() {
        XCTAssertEqual(Level(value: 0, warn: 10, red: 20), .idle)
        XCTAssertEqual(Level(value: 1, warn: 10, red: 20), .calm)
        XCTAssertEqual(Level(value: 9, warn: 10, red: 20), .calm)
        XCTAssertEqual(Level(value: 10, warn: 10, red: 20), .warn)
        XCTAssertEqual(Level(value: 19, warn: 10, red: 20), .warn)
        XCTAssertEqual(Level(value: 20, warn: 10, red: 20), .hot)
    }

    func testOverallLevelTakesTheWorstWindow() {
        XCTAssertEqual(max(Level.calm, max(Level.idle, Level.warn)), .warn)
        XCTAssertEqual(max(Level.hot, max(Level.calm, Level.warn)), .hot)
    }
}

final class ThresholdConfigTests: XCTestCase {
    func testPartialConfigKeepsDefaults() throws {
        let data = Data(#"{"warn1m": 250000, "idleBelow": 1000}"#.utf8)
        let thresholds = try JSONDecoder().decode(Thresholds.self, from: data)

        XCTAssertEqual(thresholds.warn1m, 250_000)
        XCTAssertEqual(thresholds.idleBelow, 1_000)
        XCTAssertEqual(thresholds.red1m, 1_000_000)
        XCTAssertEqual(thresholds.red1h, 20_000_000)
    }

    func testEmptyConfigIsAllDefaults() throws {
        let thresholds = try JSONDecoder().decode(Thresholds.self, from: Data("{}".utf8))
        XCTAssertEqual(thresholds.warn10m, 3_000_000)
    }
}

final class DayRecordTests: XCTestCase {
    func testCacheHitRate() {
        var record = DayRecord(key: "2026-10-22")
        record.input = 10
        record.cacheRead = 90
        XCTAssertEqual(record.cacheHitRate, 0.9, accuracy: 0.0001)
    }

    func testCacheHitRateIsZeroWithoutPromptTokens() {
        XCTAssertEqual(DayRecord(key: "2026-10-22").cacheHitRate, 0)
    }
}

final class TranscriptParsingTests: XCTestCase {
    private func line(id: String, input: Int = 10, output: Int = 5, cacheRead: Int = 0) -> Substring {
        let json = """
        {"timestamp":"2026-10-22T09:14:03.123Z","message":{"id":"\(id)","model":"deepseek-chat","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":\(cacheRead),"cache_creation_input_tokens":0}}}
        """
        return Substring(json)
    }

    func testParsesUsageAndCountsAllFourBuckets() throws {
        var seen = Set<String>()
        let sample = try XCTUnwrap(TranscriptScanner.parse(line: line(id: "msg_1", input: 10, output: 5, cacheRead: 85), seen: &seen))

        // Transcripts are stamped in UTC; buckets are local, so compare through
        // the same clock rather than pinning a timezone.
        let parsed = try XCTUnwrap(Clock.parse("2026-10-22T09:14:03.123Z"))

        XCTAssertEqual(sample.id, "msg_1")
        XCTAssertEqual(sample.model, "deepseek-chat")
        XCTAssertEqual(sample.input, 10)
        XCTAssertEqual(sample.output, 5)
        XCTAssertEqual(sample.cacheRead, 85)
        XCTAssertEqual(sample.tokens, 100)
        XCTAssertEqual(sample.minuteKey, Clock.minuteKey(parsed))
        XCTAssertEqual(sample.dayKey, Clock.dayKey(parsed))
    }

    func testDuplicateMessageIsIgnored() {
        var seen = Set<String>()
        let first = TranscriptScanner.parse(line: line(id: "msg_1"), seen: &seen)
        let second = TranscriptScanner.parse(line: line(id: "msg_1"), seen: &seen)

        XCTAssertNotNil(first)
        XCTAssertNil(second, "Claude Code records the same response more than once")
        XCTAssertEqual(seen.count, 1)
    }

    func testLinesWithoutUsageAreIgnored() {
        var seen = Set<String>()
        let line: Substring = #"{"timestamp":"2026-10-22T09:14:03Z","type":"summary"}"#
        XCTAssertNil(TranscriptScanner.parse(line: line, seen: &seen))
    }

    func testMalformedLineIsIgnored() {
        var seen = Set<String>()
        XCTAssertNil(TranscriptScanner.parse(line: "not json at all", seen: &seen))
    }
}

@MainActor
final class UsageWindowTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func store(minutes: [String: Int]) -> UsageStore {
        let store = UsageStore()
        let fixed = base
        store.now = { fixed }
        store.minutes = minutes
        return store
    }

    func testWindowsSumTheRightMinutes() {
        let store = store(minutes: [
            Clock.minuteKey(base): 100,
            Clock.minuteKey(base.addingTimeInterval(-60)): 200,
            Clock.minuteKey(base.addingTimeInterval(-600)): 300,
            Clock.minuteKey(base.addingTimeInterval(-3_600)): 400,
        ])

        // A window covers now and the previous nine minutes, so the sample
        // sitting exactly ten minutes back is outside it.
        XCTAssertEqual(store.tokens1m, 100)
        XCTAssertEqual(store.tokens(lastMinutes: 2), 300)
        XCTAssertEqual(store.tokens10m, 300)
        XCTAssertEqual(store.tokens(lastMinutes: 11), 600)
        XCTAssertEqual(store.tokens1h, 600)
        XCTAssertEqual(store.tokens(lastMinutes: 61), 1_000)
    }

    func testSparklineIsOldestFirst() {
        let store = store(minutes: [
            Clock.minuteKey(base): 7,
            Clock.minuteKey(base.addingTimeInterval(-60)): 5,
        ])

        let values = store.sparkline
        XCTAssertEqual(values.count, 60)
        XCTAssertEqual(values.last, 7)
        XCTAssertEqual(values[values.count - 2], 5)
        XCTAssertEqual(values.first, 0)
    }

    func testBucketIndexIsNewestLast() {
        let store = store(minutes: [Clock.minuteKey(base): 42])
        XCTAssertEqual(store.bucket(at: 59).tokens, 42)
        XCTAssertEqual(store.bucket(at: 0).tokens, 0)
    }

    func testReportShowsSevenDaysNewestFirst() {
        var today = DayRecord(key: Clock.dayKey(base))
        today.tokens = 10

        let store = store(minutes: [:])
        store.days = [today.key: today]

        let report = store.reportDays
        XCTAssertEqual(report.count, 7)
        XCTAssertEqual(report.first?.key, today.key)
        XCTAssertEqual(report.first?.tokens, 10)
        XCTAssertEqual(report.dropFirst().map(\.tokens), [0, 0, 0, 0, 0, 0])
    }

    func testReportFollowsConfiguredHistory() {
        let store = store(minutes: [:])
        store.historyDays = 14
        XCTAssertEqual(store.reportDays.count, 14)
    }

    func testHeadlineFallsBackToSpendWithoutABalanceProvider() {
        var record = DayRecord(key: Clock.dayKey(base))
        record.tokens = 1_000_000
        record.pricedTokens = 1_000_000
        record.spend = 0.42

        let store = store(minutes: [:])
        store.provider.balance = nil
        store.days = [record.key: record]

        XCTAssertFalse(store.showsBalance)
        XCTAssertEqual(store.headlineValue, 0.42, accuracy: 0.0001)
        XCTAssertEqual(store.headlineLabel, "spent today")
    }

    func testIngestAccumulatesSpendFromPrices() {
        let store = store(minutes: [:])
        store.pricing = Pricing(models: [
            "deepseek-flash": ModelPrice(input: 1, output: 2, cacheRead: 0.1, cacheWrite: 1),
        ])

        let sample = UsageSample(
            id: "msg_1",
            date: base,
            minuteKey: Clock.minuteKey(base),
            dayKey: Clock.dayKey(base),
            model: "deepseek-flash",
            input: 1_000_000,
            output: 1_000_000,
            cacheRead: 1_000_000,
            cacheWrite: 1_000_000
        )
        store.ingest(sample)

        // 1 + 2 + 0.1 + 1 = 4.10 per million of each bucket.
        XCTAssertEqual(store.today.spend, 4.10, accuracy: 0.0001)
        XCTAssertEqual(store.today.pricedTokens, 4_000_000)
    }

    func testIngestLeavesUnpricedModelsOutOfSpend() {
        let store = store(minutes: [:])
        store.pricing = Pricing(models: ["deepseek-flash": ModelPrice(input: 1)])

        let sample = UsageSample(
            id: "msg_1",
            date: base,
            minuteKey: Clock.minuteKey(base),
            dayKey: Clock.dayKey(base),
            model: "mystery-model",
            input: 1_000,
            output: 0,
            cacheRead: 0,
            cacheWrite: 0
        )
        store.ingest(sample)

        XCTAssertEqual(store.today.spend, 0)
        XCTAssertEqual(store.today.pricedTokens, 0)
        XCTAssertEqual(store.today.tokens, 1_000)
    }

    func testQuietWhenTenMinuteVolumeIsLow() {
        XCTAssertTrue(store(minutes: [Clock.minuteKey(base): 10]).isQuiet)
        XCTAssertFalse(store(minutes: [Clock.minuteKey(base): 100_000]).isQuiet)
    }
}

final class KeyResolutionTests: XCTestCase {
    private func temporaryFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "tokenmeter-\(UUID().uuidString).json")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testGenericEnvironmentVariableWins() throws {
        let file = try temporaryFile(#"{"env":{"ANTHROPIC_AUTH_TOKEN":"sk-file"}}"#)
        let key = KeyRef(env: "DEEPSEEK_API_KEY", file: file.path, jsonPath: "env.ANTHROPIC_AUTH_TOKEN")

        let resolved = key.resolve(environment: [
            "TOKENMETER_API_KEY": "sk-generic",
            "DEEPSEEK_API_KEY": "sk-provider",
        ])
        XCTAssertEqual(resolved, "sk-generic")
    }

    func testProviderEnvironmentVariableBeatsTheFile() throws {
        let file = try temporaryFile(#"{"env":{"ANTHROPIC_AUTH_TOKEN":"sk-file"}}"#)
        let key = KeyRef(env: "DEEPSEEK_API_KEY", file: file.path, jsonPath: "env.ANTHROPIC_AUTH_TOKEN")

        XCTAssertEqual(key.resolve(environment: ["DEEPSEEK_API_KEY": "sk-provider"]), "sk-provider")
    }

    func testReadsTheJSONPathFromClaudeSettings() throws {
        let file = try temporaryFile(#"{"env":{"ANTHROPIC_AUTH_TOKEN":"sk-file"}}"#)
        let key = KeyRef(env: "DEEPSEEK_API_KEY", file: file.path, jsonPath: "env.ANTHROPIC_AUTH_TOKEN")

        XCTAssertEqual(key.resolve(environment: [:]), "sk-file")
    }

    func testPlainFileIsTrimmedToTheKey() throws {
        let file = try temporaryFile("sk-plain\n")
        let key = KeyRef(env: nil, file: file.path, jsonPath: nil)

        XCTAssertEqual(key.resolve(environment: [:]), "sk-plain")
    }

    func testMissingFileResolvesToNil() {
        let key = KeyRef(env: "NOT_SET_ANYWHERE", file: "/nonexistent/key.json", jsonPath: nil)
        XCTAssertNil(key.resolve(environment: [:]))
    }
}

final class PricingTests: XCTestCase {
    private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let components = DateComponents(year: year, month: month, day: day, hour: hour)
        return try XCTUnwrap(calendar.date(from: components))
    }

    private func sample(
        _ model: String,
        input: Int = 0,
        output: Int = 0,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        at date: Date
    ) -> UsageSample {
        UsageSample(
            id: "msg",
            date: date,
            minuteKey: Clock.minuteKey(date),
            dayKey: Clock.dayKey(date),
            model: model,
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite
        )
    }

    func testRateIsPerMillionTokens() throws {
        let date = try utc(2026, 10, 21, 12)
        let pricing = Pricing(models: ["deepseek-flash": ModelPrice(input: 0.15, output: 0.60)])

        XCTAssertEqual(
            try XCTUnwrap(pricing.cost(of: sample("deepseek-flash", input: 1_000_000, at: date))),
            0.15,
            accuracy: 0.0001
        )
    }

    func testVendorPrefixedModelMatchesContainedKey() throws {
        let date = try utc(2026, 10, 21, 12)
        let pricing = Pricing(models: ["glm-4.6": ModelPrice(input: 1)])

        XCTAssertEqual(
            try XCTUnwrap(pricing.cost(of: sample("z-ai/glm-4.6", input: 1_000_000, at: date))),
            1,
            accuracy: 0.0001
        )
    }

    func testLongestContainedKeyWins() throws {
        let date = try utc(2026, 10, 21, 12)
        let pricing = Pricing(models: [
            "glm": ModelPrice(input: 9),
            "glm-4.6": ModelPrice(input: 1),
        ])

        XCTAssertEqual(
            try XCTUnwrap(pricing.cost(of: sample("z-ai/glm-4.6", input: 1_000_000, at: date))),
            1,
            accuracy: 0.0001
        )
    }

    func testUnknownModelIsUnpricedWithoutAFallback() throws {
        let date = try utc(2026, 10, 21, 12)
        let pricing = Pricing(models: ["deepseek-flash": ModelPrice(input: 1)])
        XCTAssertNil(pricing.cost(of: sample("mystery", input: 1_000_000, at: date)))
    }

    func testFallbackCoversUnknownModels() throws {
        let date = try utc(2026, 10, 21, 12)
        let pricing = Pricing(models: [:], fallback: ModelPrice(input: 2))
        XCTAssertEqual(
            try XCTUnwrap(pricing.cost(of: sample("mystery", input: 1_000_000, at: date))),
            2,
            accuracy: 0.0001
        )
    }

    func testPeakScheduleDoublesWeekdayPeakHours() throws {
        let pricing = Pricing(
            models: ["m": ModelPrice(input: 1)],
            schedule: PriceSchedule(peakHoursUTC: [[1, 4], [6, 10]], peakMultiplier: 2)
        )

        let peak = try utc(2026, 10, 21, 2)
        let offPeak = try utc(2026, 10, 21, 12)

        XCTAssertEqual(try XCTUnwrap(pricing.cost(of: sample("m", input: 1_000_000, at: peak))), 2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(pricing.cost(of: sample("m", input: 1_000_000, at: offPeak))), 1, accuracy: 0.0001)
    }

    func testPeakScheduleSkipsWeekends() throws {
        let schedule = PriceSchedule(peakHoursUTC: [[1, 4]], peakMultiplier: 2)
        let saturday = try utc(2026, 10, 24, 2)
        XCTAssertEqual(schedule.multiplier(at: saturday), 1)
    }

    func testPartialModelPriceKeepsOtherRatesAtZero() throws {
        let price = try JSONDecoder().decode(ModelPrice.self, from: Data(#"{"input": 3}"#.utf8))
        XCTAssertEqual(price.input, 3)
        XCTAssertEqual(price.output, 0)
        XCTAssertEqual(price.cacheRead, 0)
    }
}

final class ProviderTests: XCTestCase {
    func testDetectsDeepSeekFromBaseURL() {
        let preset = Presets.detect(
            environment: ["ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic"],
            home: FileManager.default.temporaryDirectory
        )
        XCTAssertEqual(preset.provider.name, "DeepSeek")
        XCTAssertNotNil(preset.provider.balance)
    }

    func testDetectsOpenRouterWithoutADefaultPriceTable() {
        let preset = Presets.detect(
            environment: ["ANTHROPIC_BASE_URL": "https://openrouter.ai/api/v1"],
            home: FileManager.default.temporaryDirectory
        )
        XCTAssertEqual(preset.provider.name, "OpenRouter")
        XCTAssertTrue(preset.pricing.models.isEmpty)
    }

    func testDetectsMoonshotCurrency() {
        let preset = Presets.detect(
            environment: ["ANTHROPIC_BASE_URL": "https://api.moonshot.cn/anthropic"],
            home: FileManager.default.temporaryDirectory
        )
        XCTAssertEqual(preset.provider.name, "Moonshot")
        XCTAssertEqual(preset.provider.balance?.currency, "CNY")
    }

    func testUnknownEndpointHasNoBalance() {
        let preset = Presets.detect(
            environment: ["ANTHROPIC_BASE_URL": "http://localhost:8080"],
            home: FileManager.default.temporaryDirectory
        )
        XCTAssertEqual(preset.provider.name, "Custom")
        XCTAssertNil(preset.provider.balance)
    }

    func testJSONPathWalksArraysAndObjects() throws {
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(#"{"balance_infos":[{"total_balance":12.5}]}"#.utf8))
        )
        XCTAssertEqual(JSONPath.number("balance_infos.0.total_balance", in: root), 12.5)
        XCTAssertNil(JSONPath.number("balance_infos.1.total_balance", in: root))
    }

    func testPartialKeyOverrideKeepsPresetDefaults() throws {
        let override = try JSONDecoder().decode(
            ProviderOverride.self,
            from: Data(#"{"name":"Acme","key":{"env":"ACME_KEY"}}"#.utf8)
        )
        var provider = Preset.deepSeek.provider
        provider.merge(override)

        XCTAssertEqual(provider.name, "Acme")
        XCTAssertEqual(provider.key.env, "ACME_KEY")
        XCTAssertEqual(provider.key.file, "~/.claude/settings.json")
        XCTAssertNotNil(provider.balance)
    }

    func testNullBalanceDisablesThePresetEndpoint() throws {
        let override = try JSONDecoder().decode(ProviderOverride.self, from: Data(#"{"balance":null}"#.utf8))
        var provider = Preset.deepSeek.provider
        provider.merge(override)
        XCTAssertNil(provider.balance)
    }

    func testBalanceSpecDefaults() throws {
        let spec = try JSONDecoder().decode(
            BalanceSpec.self,
            from: Data(#"{"url":"https://example.com","valuePath":"a.b"}"#.utf8)
        )
        XCTAssertEqual(spec.method, "GET")
        XCTAssertEqual(spec.currency, "USD")
        XCTAssertNil(spec.headers)
        XCTAssertNil(spec.subtractPath)
    }
}
