import Foundation
import Testing
@testable import DeskDrop

@Suite("Formatting")
struct FormattingTests {
    private let locale = Locale(identifier: "en_US")

    @Test("Byte counts use file-style units")
    func bytes() {
        #expect(FileSizeFormatter.string(fromBytes: 0, locale: locale) == "Zero KB" || FileSizeFormatter.string(fromBytes: 0, locale: locale) == "0 bytes")
        #expect(FileSizeFormatter.string(fromBytes: 1_500_000, locale: locale) == "1.5 MB")
        #expect(FileSizeFormatter.string(fromBytes: 2_000_000_000, locale: locale) == "2 GB")
        #expect(FileSizeFormatter.string(fromBytes: -5, locale: locale) == FileSizeFormatter.string(fromBytes: 0, locale: locale))
    }

    @Test("Progress never shows more than the total")
    func progress() {
        #expect(FileSizeFormatter.progress(1_000_000, of: 4_000_000, locale: locale) == "1 MB of 4 MB")
        #expect(FileSizeFormatter.progress(9_000_000, of: 4_000_000, locale: locale) == "4 MB of 4 MB")
    }

    @Test("Speed is only shown for real, positive rates")
    func speed() {
        #expect(FileSizeFormatter.speed(bytesPerSecond: 2_500_000, locale: locale) == "2.5 MB/s")
        #expect(FileSizeFormatter.speed(bytesPerSecond: 0, locale: locale) == "—")
        #expect(FileSizeFormatter.speed(bytesPerSecond: .nan, locale: locale) == "—")
    }

    @Test("Time remaining reads naturally")
    func timeRemaining() {
        #expect(FileSizeFormatter.timeRemaining(seconds: 2) == "A few seconds left")
        #expect(FileSizeFormatter.timeRemaining(seconds: 42) == "42 s left")
        #expect(FileSizeFormatter.timeRemaining(seconds: 180) == "About 3 min left")
        #expect(FileSizeFormatter.timeRemaining(seconds: 3600) == "About 1 h left")
        #expect(FileSizeFormatter.timeRemaining(seconds: 4800) == "About 1 h 20 min left")
        #expect(FileSizeFormatter.timeRemaining(seconds: -1) == nil)
        #expect(FileSizeFormatter.timeRemaining(seconds: .infinity) == nil)
    }

    @Test("Throughput needs a real time span before reporting")
    func throughput() {
        var estimator = ThroughputEstimator(window: 4, minimumSpan: 1)
        estimator.record(bytes: 0, at: 10)
        estimator.record(bytes: 500, at: 10.5)
        #expect(estimator.bytesPerSecond == nil)
        estimator.record(bytes: 2_000, at: 12)
        #expect(estimator.bytesPerSecond == 1_000)
        #expect(estimator.secondsRemaining(totalBytes: 10_000) == 8)
    }

    @Test("Throughput uses a sliding window and resets if bytes go backwards")
    func throughputWindow() {
        var estimator = ThroughputEstimator(window: 2, minimumSpan: 1)
        for (second, bytes) in [(0, 0), (1, 1_000), (2, 2_000), (3, 3_000), (4, 9_000)] {
            estimator.record(bytes: Int64(bytes), at: TimeInterval(second))
        }
        // Only the last two seconds count: (9000 − 2000) / 2, not the overall 2250/s average.
        #expect(estimator.bytesPerSecond == 3_500)
        estimator.record(bytes: 100, at: 5)
        #expect(estimator.bytesPerSecond == nil)
    }

    @Test("History dates are relative when recent")
    func historyDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(now.addingTimeInterval(-60).historyDisplayString(relativeTo: now, calendar: calendar).hasPrefix("Today"))
        #expect(now.addingTimeInterval(-86_400).historyDisplayString(relativeTo: now, calendar: calendar).hasPrefix("Yesterday"))
    }
}
