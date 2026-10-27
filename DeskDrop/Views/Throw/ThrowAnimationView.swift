import SwiftUI

/// One file "in the air" between your Mac and a colleague's.
struct Flight: Identifiable, Equatable {
    let id = UUID()
    let peerID: String
    let icon: FileIconView.Source
    let itemCount: Int
    let createdAt = Date.now
}

/// Throws a file along a curved path: it lifts, arcs with a short light trail,
/// and settles into the recipient card. Purely visual — it never implies delivery.
struct ThrowAnimationView: View {
    let flight: Flight
    let start: CGPoint
    let end: CGPoint
    let onLanded: () -> Void

    @State private var progress: Double = 0

    var body: some View {
        FlightFrame(progress: progress, start: start, end: end, flight: flight)
            .onAppear {
                withAnimation(.timingCurve(0.3, 0.0, 0.2, 1.0, duration: Theme.Motion.flightDuration)) {
                    progress = 1
                } completion: {
                    onLanded()
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Renders the flight at a given progress; SwiftUI interpolates `progress`.
private struct FlightFrame: View, @preconcurrency Animatable {
    var progress: Double
    let start: CGPoint
    let end: CGPoint
    let flight: Flight

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    private var control: CGPoint {
        let distance = hypot(end.x - start.x, end.y - start.y)
        return CGPoint(x: (start.x + end.x) / 2, y: min(start.y, end.y) - max(70, distance * 0.32))
    }

    private func point(at t: Double) -> CGPoint {
        let t = min(max(t, 0), 1)
        let u = 1 - t
        return CGPoint(x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                       y: u * u * start.y + 2 * u * t * control.y + t * t * end.y)
    }

    /// Lifts to 1.25× early in the throw, then shrinks into the card.
    private var scale: CGFloat {
        progress < 0.18 ? 1 + progress / 0.18 * 0.25 : 1.25 - (progress - 0.18) / 0.82 * 0.6
    }

    private var tokenOpacity: Double {
        progress > 0.92 ? max(0, (1 - progress) / 0.08) : 1
    }

    var body: some View {
        ZStack {
            Canvas { context, _ in
                let tail = max(0, progress - 0.28)
                guard progress - tail > 0.01 else { return }
                var trail = Path()
                for step in 0...18 {
                    let point = point(at: tail + (progress - tail) * Double(step) / 18)
                    step == 0 ? trail.move(to: point) : trail.addLine(to: point)
                }
                context.stroke(trail,
                               with: .linearGradient(Gradient(colors: [Theme.accent.opacity(0), Theme.cyan.opacity(0.7)]),
                                                     startPoint: point(at: tail), endPoint: point(at: progress)),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round))

                // A few sparks trailing the file, wobbling slightly off the path.
                for spark in 1...5 {
                    let t = progress - Double(spark) * 0.04
                    guard t > 0 else { continue }
                    let base = point(at: t)
                    let wobble = sin(Double(spark) * 1.9 + progress * 14) * 6
                    let radius = 2.4 - Double(spark) * 0.32
                    let rect = CGRect(x: base.x - radius, y: base.y + wobble - radius, width: radius * 2, height: radius * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(Theme.cyan.opacity(0.6 - Double(spark) * 0.1)))
                }
            }
            .opacity(progress < 0.9 ? 1 : max(0, (1 - progress) * 10))

            FlightToken(flight: flight)
                .scaleEffect(scale)
                .rotationEffect(.degrees(sin(progress * .pi) * (end.x >= start.x ? 9 : -9)))
                .opacity(tokenOpacity)
                .position(point(at: progress))
        }
    }
}

/// The file's icon as it flies, with a count badge for multiple items.
private struct FlightToken: View {
    let flight: Flight

    var body: some View {
        FileIconView(source: flight.icon, size: 46)
            .shadow(color: Theme.accent.opacity(0.45), radius: 12)
            .shadow(color: .black.opacity(0.3), radius: 6, y: 4)
            .overlay(alignment: .topTrailing) {
                if flight.itemCount > 1 {
                    Text("\(flight.itemCount)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.accent))
                        .offset(x: 8, y: -6)
                }
            }
    }
}
