import SwiftUI

/// bars that move with the song. They are drawn from the spectrum found when the song was analysed, so they work with both playback engines.
/// Settings > Visualizer sets the style, how many bars, the gap, the roundness, the colour and the sensitivity.
struct SpectrumView: View {
    @EnvironmentObject var player: Player
    @ObservedObject private var act = AppActive.shared
    @AppStorage("visualizer") private var style = "bars"
    @AppStorage("vizBars") private var barCount = 32
    @AppStorage("vizGap") private var gapSetting = 4.0
    @AppStorage("vizRound") private var round = 1.0
    @AppStorage("vizColor") private var colorMode = "accent"
    @AppStorage("vizBoost") private var boost = 1.0
    var height: CGFloat = 120

    /// fewer bars than the 32 that were measured: neighbours are averaged
    private static func resample(_ v: [Float], _ n: Int) -> [Float] {
        guard n > 0, n < v.count else { return v }
        return (0..<n).map { j in
            let lo = j * v.count / n
            let hi = min(v.count, max(lo + 1, (j + 1) * v.count / n))
            return v[lo..<hi].reduce(0, +) / Float(hi - lo)
        }
    }

    var body: some View {
        if style != "off", let a = player.spectrum {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !player.isPlaying || !act.active)) { _ in
                let values = Self.resample(a.frame(at: player.clock.position + 0.03), max(4, barCount))
                Canvas(rendersAsynchronously: true) { ctx, size in
                    guard !values.isEmpty else { return }
                    let n = values.count
                    let gap = CGFloat(gapSetting)
                    let w = max(1, (size.width - gap * CGFloat(n - 1)) / CGFloat(n))
                    let mirror = style == "mirror"
                    for (i, raw) in values.enumerated() {
                        let v = CGFloat(pow(min(1, raw * Float(boost)), 1.4))
                        let x = CGFloat(i) * (w + gap)
                        let h = max(3, v * (mirror ? size.height / 2 : size.height))
                        let rect = mirror
                            ? CGRect(x: x, y: size.height / 2 - h, width: w, height: h * 2)
                            : CGRect(x: x, y: size.height - h, width: w, height: h)
                        let alpha = 0.35 + 0.5 * Double(v)
                        let color: Color
                        switch colorMode {
                        case "white": color = Color.white.opacity(alpha)
                        case "rainbow": color = Color(hue: Double(i) / Double(n) * 0.85, saturation: 0.55, brightness: 1).opacity(alpha)
                        default: color = player.accent.opacity(alpha)
                        }
                        ctx.fill(Path(roundedRect: rect, cornerRadius: min(w / 2, 6 * CGFloat(round))), with: .color(color))
                    }
                }
            }
            .frame(height: height)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

/// the visualizer as the full player shows it: its height, where it sits, how wide, how strong, and on which pages (Settings > Visualizer)
struct SpectrumLayer: View {
    let page: Int
    @AppStorage("vizHeight") private var height = 110.0
    @AppStorage("vizPosition") private var position = "bottom"
    @AppStorage("vizOffset") private var offset = 80.0
    @AppStorage("vizSide") private var side = 40.0
    @AppStorage("vizOpacity") private var strength = 0.55
    @AppStorage("vizLyrics") private var onLyrics = true
    @AppStorage("vizSong") private var onSong = true
    @AppStorage("vizArtist") private var onArtist = true

    private var shown: Bool { page == 0 ? onLyrics : (page == 1 ? onSong : onArtist) }

    var body: some View {
        if shown {
            VStack(spacing: 0) {
                if position != "top" { Spacer(minLength: 0) }
                SpectrumView(height: CGFloat(height))
                    .opacity(page == 0 ? strength * 0.45 : strength)
                    .padding(.horizontal, CGFloat(side))
                    .padding(position == "top" ? .top : .bottom, position == "middle" ? 0 : CGFloat(offset))
                if position != "bottom" { Spacer(minLength: 0) }
            }
            .allowsHitTesting(false)
        }
    }
}
