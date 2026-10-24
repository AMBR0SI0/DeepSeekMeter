import XCTest
@testable import DeepSeekMeter

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

    func testReportAlwaysHasThreeDaysNewestFirst() {
        var today = DayRecord(key: Clock.dayKey(base))
        today.tokens = 10

        let store = store(minutes: [:])
        store.days = [today.key: today]

        let report = store.reportDays
        XCTAssertEqual(report.count, 3)
        XCTAssertEqual(report.first?.key, today.key)
        XCTAssertEqual(report.first?.tokens, 10)
        XCTAssertEqual(report.dropFirst().map(\.tokens), [0, 0])
    }

    func testQuietWhenTenMinuteVolumeIsLow() {
        XCTAssertTrue(store(minutes: [Clock.minuteKey(base): 10]).isQuiet)
        XCTAssertFalse(store(minutes: [Clock.minuteKey(base): 100_000]).isQuiet)
    }
}

final class CredentialTests: XCTestCase {
    func testEnvironmentKeyWins() {
        XCTAssertEqual(DeepSeek.token(environment: ["DEEPSEEK_API_KEY": "sk-test"]), "sk-test")
    }
}
