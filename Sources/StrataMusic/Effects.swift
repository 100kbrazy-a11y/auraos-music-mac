import SwiftUI

/// slow colour blobs from the cover, like the Android player's background
struct AuroraBackground: View {
    var color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                ZStack {
                    Color(red: 0.03, green: 0.03, blue: 0.04)
                    Circle().fill(color.opacity(0.55)).frame(width: w * 0.7).offset(x: CGFloat(sin(t * 0.13)) * w * 0.25 - w * 0.15, y: CGFloat(cos(t * 0.11)) * h * 0.2 - h * 0.15)
                    Circle().fill(color.opacity(0.35)).frame(width: w * 0.55).offset(x: CGFloat(cos(t * 0.09)) * w * 0.3 + w * 0.2, y: CGFloat(sin(t * 0.14)) * h * 0.25 + h * 0.2)
                    Circle().fill(color.opacity(0.25)).frame(width: w * 0.45).offset(x: CGFloat(sin(t * 0.07 + 2)) * w * 0.3, y: CGFloat(cos(t * 0.1 + 1)) * h * 0.3 + h * 0.1)
                }
                .frame(width: w, height: h)
                .blur(radius: 110)
                .overlay(LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .center, endPoint: .bottom))
            }
        }
        .clipped()
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
}

/// the Thanksgiving update's falling brown, yellow and red leaves
struct FallingLeaves: View {
    private struct Leaf { var x: Double; var speed: Double; var size: Double; var phase: Double; var sway: Double; var rot: Double; var spin: Double; var color: Color }

    private static let leaves: [Leaf] = {
        var g = SeededGenerator(state: 1123)
        let palette: [Color] = [
            Color(red: 0.55, green: 0.33, blue: 0.14), Color(red: 0.42, green: 0.25, blue: 0.10), Color(red: 0.72, green: 0.45, blue: 0.16),
            Color(red: 0.93, green: 0.72, blue: 0.20), Color(red: 0.96, green: 0.80, blue: 0.30), Color(red: 0.80, green: 0.20, blue: 0.12), Color(red: 0.65, green: 0.12, blue: 0.10),
        ]
        return (0..<24).map { _ in
            Leaf(x: Double.random(in: 0...1, using: &g), speed: Double.random(in: 38...85, using: &g), size: Double.random(in: 0.7...1.6, using: &g),
                 phase: Double.random(in: 0...1, using: &g), sway: Double.random(in: 0.5...1.4, using: &g), rot: Double.random(in: 0...6.28, using: &g),
                 spin: Double.random(in: -1.2...1.2, using: &g), color: palette[Int.random(in: 0..<palette.count, using: &g)])
        }
    }()

    private static let leafPath: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: -12))
        p.addCurve(to: CGPoint(x: 0, y: 12), control1: CGPoint(x: 13, y: -6), control2: CGPoint(x: 10, y: 8))
        p.addCurve(to: CGPoint(x: 0, y: -12), control1: CGPoint(x: -10, y: 8), control2: CGPoint(x: -13, y: -6))
        p.closeSubpath()
        return p
    }()
    private static let rib: Path = { var p = Path(); p.move(to: CGPoint(x: 0, y: -11)); p.addLine(to: CGPoint(x: 0, y: 14)); return p }()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                for l in Self.leaves {
                    let travel = Double(size.height) + 120
                    let cycle = travel / l.speed
                    let p = ((t + l.phase * cycle).truncatingRemainder(dividingBy: cycle)) / cycle
                    let y = -60 + p * travel
                    let x = l.x * Double(size.width) + sin(t * l.sway + l.phase * 6) * 40
                    var c = ctx
                    c.translateBy(x: CGFloat(x), y: CGFloat(y))
                    c.rotate(by: .radians(l.rot + t * l.spin))
                    c.scaleBy(x: CGFloat(l.size), y: CGFloat(l.size))
                    c.fill(Self.leafPath, with: .color(l.color.opacity(0.85)))
                    c.stroke(Self.rib, with: .color(.black.opacity(0.25)), lineWidth: 0.8)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
