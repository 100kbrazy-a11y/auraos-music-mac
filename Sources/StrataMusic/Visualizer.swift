import SwiftUI

/// bars that move with the song. They are drawn from the spectrum found when the song was analysed, so they work with both playback engines.
struct SpectrumView: View {
    @EnvironmentObject var player: Player
    @ObservedObject private var act = AppActive.shared
    @AppStorage("visualizer") private var style = "bars"
    var height: CGFloat = 120

    var body: some View {
        if style != "off", let a = player.spectrum {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !player.isPlaying || !act.active)) { _ in
                let values = a.frame(at: player.clock.position + 0.03)
                Canvas(rendersAsynchronously: true) { ctx, size in
                    guard !values.isEmpty else { return }
                    let n = values.count
                    let gap: CGFloat = 4
                    let w = (size.width - gap * CGFloat(n - 1)) / CGFloat(n)
                    let mirror = style == "mirror"
                    for (i, raw) in values.enumerated() {
                        let v = CGFloat(pow(raw, 1.4))
                        let x = CGFloat(i) * (w + gap)
                        let h = max(3, v * (mirror ? size.height / 2 : size.height))
                        let rect = mirror
                            ? CGRect(x: x, y: size.height / 2 - h, width: w, height: h * 2)
                            : CGRect(x: x, y: size.height - h, width: w, height: h)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: min(w / 2, 6)), with: .color(player.accent.opacity(0.35 + 0.5 * Double(v))))
                    }
                }
            }
            .frame(height: height)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}
