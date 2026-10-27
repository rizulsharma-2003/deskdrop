import SwiftUI

/// The full-screen, click-through light layer drawn above other apps during file
/// drags, sends and arrivals: a liquid glow along assigned screen edges, a halo
/// around colleagues shown at a held file, and a burst of liquid light that wells
/// up at the edge or corner when a file is sent or a request arrives.
struct ProximityEffectView: View {
    /// The screen this layer covers, in global coordinates.
    let screenFrame: CGRect
    let state: DragOverlayState

    var body: some View {
        let snapshot = EffectSnapshot(state: state, screen: screenFrame)
        TimelineView(.animation(minimumInterval: nil, paused: !snapshot.isAnimating)) { timeline in
            Canvas { context, size in
                ProximityEffects.draw(snapshot, in: context, size: size, now: timeline.date)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Everything one screen's layer needs, converted to its local, top-left-origin space.
struct EffectSnapshot {
    struct EdgeGlow {
        let x: CGFloat
        let y: CGFloat
        let intensity: CGFloat
        let isOpen: Bool
        let isTargeted: Bool
    }

    struct Halo {
        let center: CGPoint
        let radius: CGFloat
        let shownAt: Date
        let target: CGPoint?
    }

    struct Flash {
        let origin: CGPoint
        let edge: ScreenEdge?
        let kind: DragOverlayState.Burst.Kind
        let start: Date
    }

    var glows: [EdgeGlow] = []
    var halo: Halo?
    var flashes: [Flash] = []
    var reduceMotion = false

    var isAnimating: Bool { !glows.isEmpty || halo != nil || !flashes.isEmpty }

    @MainActor
    init(state: DragOverlayState, screen: CGRect) {
        func local(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x - screen.minX, y: screen.maxY - point.y)
        }
        let area = screen.insetBy(dx: -2, dy: -2)
        reduceMotion = state.reduceMotion

        for (edge, geometry) in state.edgeGeometry {
            guard area.contains(CGPoint(x: geometry.x, y: (geometry.minY + geometry.maxY) / 2)) else { continue }
            let isOpen = state.openEdges.contains(edge)
            let intensity = max(state.edgeProximity[edge] ?? 0, isOpen ? 1 : 0)
            guard intensity > 0 else { continue }
            let y = min(max(state.cursor.y, geometry.minY), geometry.maxY)
            let point = local(CGPoint(x: geometry.x, y: y))
            glows.append(EdgeGlow(x: point.x, y: point.y, intensity: CGFloat(intensity), isOpen: isOpen,
                                  isTargeted: state.targetedEdge == edge))
        }

        if let ring = state.ring, area.contains(ring.center) {
            let target = state.targetedOrb.flatMap { ring.positions[$0] }.map(local)
            halo = Halo(center: local(ring.center), radius: ring.radius, shownAt: ring.shownAt, target: target)
        }

        flashes = state.bursts
            .filter { area.contains($0.origin) }
            .map { Flash(origin: local($0.origin), edge: $0.edge, kind: $0.kind, start: $0.start) }
    }
}

enum ProximityEffects {
    static let burstDuration: TimeInterval = 1.7
    static let spectrum: [Color] = [Theme.cyan, Theme.accent, Theme.violet, Theme.pink, Theme.cyan]

    static func draw(_ snapshot: EffectSnapshot, in context: GraphicsContext, size: CGSize, now: Date) {
        let time = now.timeIntervalSinceReferenceDate
        for glow in snapshot.glows {
            drawEdgeGlow(glow, in: context, time: time)
        }
        if let halo = snapshot.halo {
            drawHalo(halo, in: context, now: now, time: time, reduceMotion: snapshot.reduceMotion)
        }
        for flash in snapshot.flashes {
            let elapsed = now.timeIntervalSince(flash.start)
            guard elapsed >= 0, elapsed < burstDuration else { continue }
            if snapshot.reduceMotion {
                drawSoftFlash(flash, elapsed: elapsed, in: context)
            } else {
                drawBurst(flash, elapsed: elapsed, in: context, size: size)
            }
        }
    }

    // MARK: - Edge glow

    /// A liquid curtain of light hugging the edge, strongest at the cursor.
    private static func drawEdgeGlow(_ glow: EffectSnapshot.EdgeGlow, in context: GraphicsContext, time: Double) {
        let intensity = glow.intensity
        let boost: CGFloat = glow.isTargeted ? 1.4 : (glow.isOpen ? 1.15 : 1)
        for blob in 0..<5 {
            let phase = time * 1.6 + Double(blob) * 1.27
            let y = glow.y + CGFloat(sin(phase) * 70) + CGFloat(blob - 2) * 70
            let radiusX = (36 + 150 * intensity * boost) * CGFloat(0.85 + 0.2 * sin(phase * 1.9))
            let radiusY = (140 + 70 * CGFloat(sin(phase * 0.8))) * (0.7 + 0.5 * intensity)
            let color = spectrum[blob % 4]
            softBlob(context, center: CGPoint(x: glow.x, y: y), radiusX: radiusX, radiusY: radiusY,
                     colors: [color.opacity(0.55 * intensity), color.opacity(0.2 * intensity), .clear])
        }
        var filament = context
        filament.blendMode = .plusLighter
        let height = 260 + 260 * intensity
        let rect = CGRect(x: glow.x - 2, y: glow.y - height / 2, width: 4, height: height)
        filament.fill(Path(rect), with: .linearGradient(
            Gradient(colors: [.clear, .white.opacity(0.95 * intensity), .clear]),
            startPoint: CGPoint(x: glow.x, y: rect.minY), endPoint: CGPoint(x: glow.x, y: rect.maxY)))
    }

    // MARK: - Halo around a held file

    private static func drawHalo(_ halo: EffectSnapshot.Halo, in context: GraphicsContext, now: Date, time: Double,
                                 reduceMotion: Bool) {
        let appear = min(1, now.timeIntervalSince(halo.shownAt) / 0.4)
        let radius = halo.radius * CGFloat(reduceMotion ? 1 : easeOutBack(appear))
        guard radius > 1 else { return }
        let circle = Path(ellipseIn: CGRect(center: halo.center, radius: radius))
        softBlob(context, center: halo.center, radiusX: radius * 1.3, radiusY: radius * 1.3,
                 colors: [Theme.accent.opacity(0.2), Theme.violet.opacity(0.08), .clear])

        let shading = GraphicsContext.Shading.conicGradient(Gradient(colors: spectrum), center: halo.center,
                                                            angle: .radians(reduceMotion ? 0 : time * 0.9))
        var glow = context
        glow.opacity = 0.25
        glow.stroke(circle, with: shading, lineWidth: 18)
        context.stroke(circle, with: shading, lineWidth: 2.5)

        if let target = halo.target {
            var beam = context
            beam.blendMode = .plusLighter
            var path = Path()
            path.move(to: halo.center)
            path.addLine(to: target)
            beam.stroke(path, with: .linearGradient(Gradient(colors: [.white.opacity(0), Theme.cyan]),
                                                    startPoint: halo.center, endPoint: target),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
            beam.opacity = 0.3
            beam.stroke(path, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 14, lineCap: .round))
        }
    }

    // MARK: - Send / arrival burst

    /// Light wells up where the file leaves (or a request arrives) and stays
    /// anchored there: liquid blobs pour out and spread along the edge, a white-hot
    /// core swells and fades, filaments race along the edge, and sparks twinkle and
    /// drift nearby. Nothing sweeps across the rest of the screen.
    private static func drawBurst(_ flash: EffectSnapshot.Flash, elapsed: Double, in context: GraphicsContext, size: CGSize) {
        let origin = flash.origin
        let scale: CGFloat = flash.kind == .arrival ? 0.75 : 1
        // `along` runs parallel to the edge; `inward` points into the screen (y grows downward).
        let along: CGVector
        let inward: CGVector
        switch flash.edge {
        case .left:
            along = CGVector(dx: 0, dy: 1)
            inward = CGVector(dx: 1, dy: 0)
        case .right:
            along = CGVector(dx: 0, dy: 1)
            inward = CGVector(dx: -1, dy: 0)
        case nil:
            // Arrivals glow down from the top edge.
            along = CGVector(dx: 1, dy: 0)
            inward = CGVector(dx: 0, dy: 1)
        }
        func point(_ alongOffset: CGFloat, _ inwardOffset: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + along.dx * alongOffset + inward.dx * inwardOffset,
                    y: origin.y + along.dy * alongOffset + inward.dy * inwardOffset)
        }
        func blob(at center: CGPoint, alongRadius: CGFloat, inwardRadius: CGFloat, colors: [Color]) {
            if along.dx == 0 {
                softBlob(context, center: center, radiusX: inwardRadius, radiusY: alongRadius, colors: colors)
            } else {
                softBlob(context, center: center, radiusX: alongRadius, radiusY: inwardRadius, colors: colors)
            }
        }

        let fade = CGFloat(1 - smoothstep(0.75, burstDuration, elapsed))
        let wobble = CGFloat(1 + 0.07 * sin(elapsed * 9) * max(0, 1 - elapsed))

        // 1. Liquid blobs pour out and slide along the edge in both directions.
        for index in 0..<8 {
            let side: CGFloat = index.isMultiple(of: 2) ? 1 : -1
            let rank = CGFloat(index / 2)
            let local = CGFloat(easeOutCubic(min(1, max(0, (elapsed - Double(index) * 0.03) / 0.6))))
            guard local > 0 else { continue }
            let center = point(side * rank * 120 * local * scale,
                               (30 + 70 * CGFloat(hash(index, 5))) * local * scale * (1 - rank * 0.15))
            let radius = (80 + 70 * CGFloat(hash(index, 6))) * scale * (0.55 + 0.45 * local) * wobble
            let color = spectrum[index % 4]
            blob(at: center, alongRadius: radius * 1.5, inwardRadius: radius,
                 colors: [color.opacity(0.6 * fade), color.opacity(0.22 * fade), .clear])
        }

        // 2. A tall soft flare hugging the edge.
        let flare = CGFloat(smoothstep(0, 0.25, elapsed)) * fade
        blob(at: origin, alongRadius: (flash.edge == nil ? size.width : size.height) * 0.35 * scale,
             inwardRadius: (60 + 80 * flare) * scale,
             colors: [Theme.cyan.opacity(0.45 * flare), Theme.violet.opacity(0.22 * flare), .clear])

        // 3. The white-hot core swells, then sinks back into the edge.
        let swell = CGFloat(easeOutCubic(min(1, elapsed / 0.4)))
        let core = CGFloat(1 - smoothstep(0.3, 1.1, elapsed))
        if core > 0 {
            blob(at: point(0, 10 * swell), alongRadius: 300 * swell * scale, inwardRadius: 170 * swell * scale * wobble,
                 colors: [.white.opacity(0.95 * core), Theme.cyan.opacity(0.7 * core), Theme.accent.opacity(0.3 * core), .clear])
        }

        // 4. Filaments of light racing along the edge both ways.
        let run = CGFloat(easeOutCubic(min(1, elapsed / 0.9)))
        let lineFade = CGFloat(1 - smoothstep(0.55, 1.5, elapsed))
        if lineFade > 0 {
            let reach = (flash.edge == nil ? size.width : size.height) * 0.6 * run * scale
            for side in [CGFloat(1), -1] {
                var path = Path()
                path.move(to: point(0, 1.5))
                path.addLine(to: point(side * reach, 1.5))
                let shading = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [.white.opacity(lineFade), Theme.cyan.opacity(0.8 * lineFade),
                                      Theme.violet.opacity(0.4 * lineFade), .clear]),
                    startPoint: point(0, 0), endPoint: point(side * reach, 0))
                var glow = context
                glow.blendMode = .plusLighter
                glow.opacity = 0.3
                glow.stroke(path, with: shading, style: StrokeStyle(lineWidth: 22, lineCap: .round))
                var filament = context
                filament.blendMode = .plusLighter
                filament.stroke(path, with: shading, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
        }

        // 5. Sparks that drift out a little, float, and twinkle near the edge.
        let sparkProgress = min(1, elapsed / 1.4)
        if sparkProgress < 1 {
            var sparks = context
            sparks.blendMode = .plusLighter
            for spark in 0..<36 {
                let spread = CGFloat(hash(spark, 1) - 0.5) * 2
                let depth = CGFloat(easeOutCubic(sparkProgress)) * CGFloat(30 + hash(spark, 2) * 200) * scale
                let lift = -CGFloat(elapsed) * CGFloat(20 + hash(spark, 4) * 40)
                var position = point(spread * 220 * scale * CGFloat(0.4 + 0.6 * sparkProgress), depth)
                position.y += lift
                let twinkle = 0.55 + 0.45 * sin(elapsed * 18 + Double(spark))
                let radius = CGFloat(1 + hash(spark, 3) * 2.4)
                let color = spectrum[spark % 4]
                sparks.opacity = (1 - sparkProgress) * twinkle
                sparks.fill(Path(ellipseIn: CGRect(center: position, radius: radius * 3.2)), with: .color(color.opacity(0.18)))
                sparks.fill(Path(ellipseIn: CGRect(center: position, radius: radius)), with: .color(color))
            }
        }
    }

    /// Reduce Motion: a gentle glow that fades in place, with no movement.
    private static func drawSoftFlash(_ flash: EffectSnapshot.Flash, elapsed: Double, in context: GraphicsContext) {
        let fade = CGFloat(smoothstep(0, 0.2, elapsed) * (1 - smoothstep(0.6, 1.4, elapsed)))
        softBlob(context, center: flash.origin, radiusX: flash.edge == nil ? 180 : 120, radiusY: 240,
                 colors: [Theme.cyan.opacity(0.5 * fade), Theme.accent.opacity(0.2 * fade), .clear])
    }

    // MARK: - Helpers

    /// A soft elliptical pool of light (a radial gradient on a stretched circle).
    static func softBlob(_ context: GraphicsContext, center: CGPoint, radiusX: CGFloat, radiusY: CGFloat, colors: [Color]) {
        guard radiusX > 0.5, radiusY > 0.5 else { return }
        var layer = context
        layer.blendMode = .plusLighter
        layer.translateBy(x: center.x, y: center.y)
        layer.scaleBy(x: radiusX / radiusY, y: 1)
        layer.fill(Path(ellipseIn: CGRect(center: .zero, radius: radiusY)),
                   with: .radialGradient(Gradient(colors: colors), center: .zero, startRadius: 0, endRadius: radiusY))
    }

    static func easeOutCubic(_ x: Double) -> Double {
        1 - pow(1 - min(max(x, 0), 1), 3)
    }

    static func easeOutBack(_ x: Double) -> Double {
        let c1 = 1.70158
        let c3 = c1 + 1
        let t = min(max(x, 0), 1) - 1
        return 1 + c3 * t * t * t + c1 * t * t
    }

    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Stable pseudo-random 0…1 so sparks look scattered but never flicker between frames.
    static func hash(_ a: Int, _ b: Int) -> Double {
        let value = sin(Double(a) * 12.9898 + Double(b) * 78.233) * 43758.5453
        return value - floor(value)
    }
}

extension CGRect {
    init(center: CGPoint, radius: CGFloat) {
        self.init(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }
}
