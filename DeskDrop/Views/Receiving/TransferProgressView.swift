import SwiftUI

/// Real, measured progress: percentage, bytes, speed and time remaining once
/// there is enough data to estimate them.
struct TransferProgressView: View {
    let transfer: Transfer

    private var isVerifying: Bool { transfer.phase == .verifying }
    private var isWaitingToStart: Bool { transfer.phase == .accepted && transfer.bytesTransferred == 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ProgressBar(fraction: transfer.fractionCompleted, isIndeterminate: isVerifying || isWaitingToStart)
            HStack(spacing: 8) {
                Text(leadingText)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary.opacity(0.8))
                Text(FileSizeFormatter.progress(transfer.bytesTransferred, of: transfer.totalBytes))
                Spacer(minLength: 4)
                if !isVerifying, let speed = transfer.bytesPerSecond {
                    Text(FileSizeFormatter.speed(bytesPerSecond: speed))
                }
                if !isVerifying, let remaining = transfer.secondsRemaining.flatMap(FileSizeFormatter.timeRemaining) {
                    Text(remaining)
                }
            }
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Transfer progress"))
        .accessibilityValue(Text(accessibilityValue))
        .accessibilityIdentifier("transferProgress")
    }

    private var leadingText: String {
        if isVerifying {
            return transfer.direction == .outgoing ? String(localized: "Verifying…") : String(localized: "Saving…")
        }
        if isWaitingToStart { return String(localized: "Starting…") }
        return "\(Int((transfer.fractionCompleted * 100).rounded(.down)))%"
    }

    private var accessibilityValue: String {
        let percent = Int((transfer.fractionCompleted * 100).rounded(.down))
        return String(localized: "\(percent) percent, \(FileSizeFormatter.progress(transfer.bytesTransferred, of: transfer.totalBytes))")
    }
}

/// A slim capsule bar. The indeterminate state is a slow sweep, or a static
/// half-filled bar when Reduce Motion is on.
struct ProgressBar: View {
    let fraction: Double
    var isIndeterminate = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hairlineStrong)
                if isIndeterminate {
                    if reduceMotion {
                        Capsule().fill(Theme.accentGradient).opacity(0.5)
                    } else {
                        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                            let cycle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                            let width = geometry.size.width * 0.3
                            Capsule()
                                .fill(Theme.accentGradient)
                                .frame(width: width)
                                .offset(x: (geometry.size.width + width) * cycle - width)
                        }
                        .clipShape(Capsule())
                    }
                } else {
                    Capsule()
                        .fill(Theme.accentGradient)
                        .frame(width: max(5, geometry.size.width * fraction))
                        .animation(.linear(duration: 0.25), value: fraction)
                }
            }
        }
        .frame(height: 5)
    }
}
