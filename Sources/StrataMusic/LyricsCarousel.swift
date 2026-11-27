import SwiftUI

/// words laid out left to right, wrapping onto new lines like text does (each word is its own view so it can light up on its own)
@available(macOS 13, *)
struct FlowLayout: Layout {
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, width: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > maxW { y += rowH + lineSpacing; x = 0; rowH = 0 }
            x += sz.width; rowH = max(rowH, sz.height); width = max(width, x)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX { y += rowH + lineSpacing; x = bounds.minX; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width; rowH = max(rowH, sz.height)
        }
    }
}

/// one word: dim until it is sung, then filled from left to right at the speed it is sung; the word being sung is a little bigger
struct WordView: View {
    let text: String
    let progress: Double
    let spaceAfter: Bool
    let size: CGFloat

    var body: some View {
        let active = progress > 0 && progress < 1
        ZStack(alignment: .leading) {
            Text(text).foregroundStyle(Color.white.opacity(0.38))
            if progress >= 1 {
                Text(text).foregroundStyle(Color.white)
            } else if progress > 0 {
                Text(text).foregroundStyle(Color.white)
                    .mask(LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: progress),
                        .init(color: .clear, location: min(1, progress + 0.22)),
                    ], startPoint: .leading, endPoint: .trailing))
            }
        }
        .padding(.trailing, spaceAfter ? size * 0.28 : 0)
        .scaleEffect(active ? 1.09 : 1, anchor: .bottomLeading)
        .animation(.spring(response: 0.32, dampingFraction: 0.5), value: active)
    }
}

/// the line being sung, lit word by word. It follows the player's clock between the player's own reports, so the highlight
/// moves smoothly and reaches each word at the moment it is sung.
struct LiveLine: View {
    let line: LyricLine
    @ObservedObject var clock: Clock
    let offset: Double
    let size: CGFloat
    let playing: Bool
    @ObservedObject private var act = AppActive.shared

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !playing || !act.active)) { _ in
            let t = clock.live + 0.05 - offset
            WordFlow(lineSpacing: size * 0.06, count: line.words.count) { i in
                    let w = line.words[i]
                    let following = i + 1 < line.words.count ? line.words[i + 1].start : (line.sungEnd > w.start + 0.3 ? line.sungEnd : max(w.start + 0.4, line.end - 0.1))
                    // a word is lit while it is sung: up to where the file says it stops, not across the pause after it
                    let next = w.end.map { min(max($0, w.start + 0.1), following) } ?? following
                    // a word held through a pause still finishes quickly
                    let dur = max(0.08, min(next - w.start, 1.6))
                    let p = max(0, min(1, (t - w.start) / dur))
                    let shown = LyricsFilter.clean(w.text)
                    WordView(text: shown.trimmingCharacters(in: .whitespaces), progress: p, spaceAfter: shown.hasSuffix(" "), size: size)
            }
        }
    }
}

/// lines sit on a gentle curve like a wheel: the further a line is from the one being sung, the further it slides left, the smaller and dimmer it gets,
/// and it turns away a little. [focus] is an animated copy of the current line's number, so changing line moves them all together, with a bounce.
struct CarouselEffect: ViewModifier, Animatable {
    var index: Double
    var focus: Double
    var lit = false           // a line being sung is drawn as if it were the focus, even when it isn't the one the wheel is turned to
    var floor = 0.16          // how bright the lines far from the sung one stay (Settings > Lyrics)
    var curve = 1.0           // how much the wheel curves and shrinks away from the sung line
    var animatableData: Double { get { focus } set { focus = newValue } }

    func body(content: Content) -> some View {
        let d = lit ? 0 : index - focus
        let a = min(abs(d), 4)
        return content
            .scaleEffect(1 - a * 0.03 * curve, anchor: .leading)
            .rotation3DEffect(.degrees(max(-3, min(3, d)) * -3 * curve), axis: (x: 0, y: 1, z: 0), anchor: .leading, perspective: 0.5)
            .offset(x: -(1 - cos(a * 0.5)) * 64 * curve)
            .opacity(floor + (1 - floor) * exp(-a * 0.9))
    }
}

/// "• • •" for a stretch with nothing sung (the start and end of a song, a long break): the dots fill one by one as the next line gets closer
struct GapDots: View {
    let range: ClosedRange<Double>          // lyric time, from the end of the last line to the start of the next
    let clock: Clock
    let offset: Double
    let live: Bool
    let playing: Bool

    var body: some View {
        if live {
            LiveDots(range: range, clock: clock, offset: offset, playing: playing)
        } else {
            // not the stretch we are in: fixed, empty before it and full after it, and nothing follows the clock
            DotsShape(progress: clock.position + 0.2 - offset >= range.upperBound ? 1 : 0)
        }
    }
}

private struct LiveDots: View {
    let range: ClosedRange<Double>
    @ObservedObject var clock: Clock
    let offset: Double
    let playing: Bool
    @ObservedObject private var act = AppActive.shared

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !playing || !act.active)) { _ in
            let t = clock.live + 0.05 - offset
            DotsShape(progress: max(0, min(1, (t - range.lowerBound) / max(0.5, range.upperBound - range.lowerBound))))
        }
    }
}

private struct DotsShape: View {
    let progress: Double
    var body: some View {
        HStack(spacing: 14) {
            ForEach(0..<3, id: \.self) { k in
                let f = max(0, min(1, progress * 3 - Double(k)))
                Circle().fill(Color.white.opacity(0.28 + 0.72 * f)).frame(width: 20, height: 20).scaleEffect(0.8 + 0.3 * f)
            }
        }
        .padding(.vertical, 12)
    }
}
