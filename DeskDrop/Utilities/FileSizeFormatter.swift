import Foundation

/// Formatting for byte counts, transfer rates and remaining time.
enum FileSizeFormatter {
    static func string(fromBytes bytes: Int64, locale: Locale = .autoupdatingCurrent) -> String {
        let style = ByteCountFormatStyle(style: .file, allowedUnits: .all, spellsOutZero: false,
                                         includesActualByteCount: false, locale: locale)
        return style.format(max(0, bytes))
    }

    /// "12.4 MB of 1.2 GB"
    static func progress(_ completed: Int64, of total: Int64, locale: Locale = .autoupdatingCurrent) -> String {
        let done = string(fromBytes: min(completed, total), locale: locale)
        let all = string(fromBytes: total, locale: locale)
        return String(localized: "\(done) of \(all)")
    }

    /// "24.1 MB/s"
    static func speed(bytesPerSecond: Double, locale: Locale = .autoupdatingCurrent) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "—" }
        return String(localized: "\(string(fromBytes: Int64(bytesPerSecond.rounded()), locale: locale))/s")
    }

    /// A short, human estimate: "12 s left", "About 3 min left", "About 1 h 20 min left".
    static func timeRemaining(seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let total = Int(seconds.rounded(.up))
        switch total {
        case ..<5:
            return String(localized: "A few seconds left")
        case ..<60:
            return String(localized: "\(total) s left")
        case ..<3600:
            let minutes = Int((Double(total) / 60).rounded())
            return String(localized: "About \(max(1, minutes)) min left")
        default:
            let hours = total / 3600
            let minutes = (total % 3600) / 60
            return minutes == 0
                ? String(localized: "About \(hours) h left")
                : String(localized: "About \(hours) h \(minutes) min left")
        }
    }
}
