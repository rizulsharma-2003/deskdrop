import Foundation

/// Measures transfer speed from real byte counts over a sliding window.
/// Reports nothing until enough time has passed for the number to mean something.
struct ThroughputEstimator: Equatable, Sendable {
    private struct Sample: Equatable, Sendable {
        let time: TimeInterval
        let bytes: Int64
    }

    private var samples: [Sample] = []
    let window: TimeInterval
    let minimumSpan: TimeInterval

    init(window: TimeInterval = 4, minimumSpan: TimeInterval = 1) {
        self.window = window
        self.minimumSpan = minimumSpan
    }

    mutating func record(bytes: Int64, at time: TimeInterval) {
        if let last = samples.last {
            if bytes < last.bytes {
                samples.removeAll()
            } else if time <= last.time {
                return
            }
        }
        samples.append(Sample(time: time, bytes: bytes))
        // Keep one sample at or before the window start so the span covers the window.
        let cutoff = time - window
        while samples.count > 2, samples[1].time <= cutoff {
            samples.removeFirst()
        }
    }

    var bytesPerSecond: Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let span = last.time - first.time
        guard span >= minimumSpan else { return nil }
        let rate = Double(last.bytes - first.bytes) / span
        return rate > 0 ? rate : nil
    }

    func secondsRemaining(totalBytes: Int64) -> Double? {
        guard let rate = bytesPerSecond, let last = samples.last else { return nil }
        return Double(max(0, totalBytes - last.bytes)) / rate
    }
}
