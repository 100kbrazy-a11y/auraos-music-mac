import SwiftUI
import AppKit

/// the full-screen player: three pages (Lyrics, Current Song, Artist) and the little glass pill that switches them.
/// The pages sit side by side on a strip. A two-finger swipe on the trackpad drags the strip with your fingers; let go past the
/// middle (or with a flick) and it slides to the next page, bring it back and it returns to where it was.
struct FullPlayerView: View {
    @EnvironmentObject var player: Player
    var close: () -> Void
    @State private var page: Int
    /// where the strip is, counted in pages along the pill's order: 1 is the second page, 1.5 is halfway to the third
    @State private var pos: CGFloat
    /// pages that stay drawn until a slide has finished
    @State private var keep: Set<Int> = []
    @State private var keepGen = 0
    @State private var hoverClose = false
    @State private var isFull = false
    @AppStorage("playerPages") private var pageOrder = "0,1,2"
    @AppStorage("showPill") private var showPill = true

    init(close: @escaping () -> Void) {
        self.close = close
        let d = UserDefaults.standard
        let saved = d.object(forKey: "playerStart") as? Int ?? 1
        let start = (0...2).contains(saved) ? saved : 1
        let order = PlayerPages.parse(d.string(forKey: "playerPages") ?? "0,1,2")
        _page = State(initialValue: start)
        _pos = State(initialValue: CGFloat(order.firstIndex(of: start) ?? 0))
    }

    private var order: [Int] { PlayerPages.parse(pageOrder) }

    /// the pages that have to be drawn right now: the ones the strip is showing, the chosen one, and any still sliding away
    private var drawnPages: [Int] {
        let o = order
        guard !o.isEmpty else { return [] }
        let lo = min(max(Int(pos.rounded(.down)), 0), o.count - 1)
        let hi = min(max(Int(pos.rounded(.up)), 0), o.count - 1)
        var set = Set(o[lo...hi])
        set.insert(page)
        set.formUnion(keep)
        return o.filter { set.contains($0) }
    }

    @ViewBuilder private func pageContent(_ p: Int) -> some View {
        Group {
            switch p {
            case 0: LyricsPage()
            case 2: ArtistPage()
            default: SongPage()
            }
        }
        // the Current Song page centres itself in the whole window; the others keep clear of the buttons
        .padding(.top, p == 1 ? 0 : (isFull ? 100 : 124)).padding(.bottom, p == 1 ? 0 : 92)
    }

    /// slides the strip to the page at [index] (a spring), keeping every page it passes drawn until it has arrived
    private func settle(to index: Int, page newPage: Int? = nil) {
        let o = order
        guard o.indices.contains(index) else { return }
        let lo = min(max(Int(pos.rounded(.down)), 0), index), hi = max(min(Int(pos.rounded(.up)), o.count - 1), index)
        keep = Set(o[lo...hi])
        keepGen += 1
        let gen = keepGen
        withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) {
            pos = CGFloat(index)
            if let n = newPage { page = n }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { if keepGen == gen { keep = [] } }
    }

    /// the fingers are down and moving: the strip follows them one to one (with a rubber band at the first and last page)
    private func dragged(_ travel: CGFloat, _ width: CGFloat) {
        guard width > 0, let i = order.firstIndex(of: page) else { return }
        let moved = min(max(travel / width, -1), 1)
        var p = CGFloat(i) - moved
        let last = CGFloat(order.count - 1)
        if p < 0 { p *= 0.3 } else if p > last { p = last + (p - last) * 0.3 }
        keepGen += 1
        var t = Transaction(animation: nil); t.disablesAnimations = true
        withTransaction(t) { pos = p }
    }

    /// the fingers lifted: go to the neighbouring page if they were pulled far enough, or flicked, otherwise slide back
    private func dragEnded(_ travel: CGFloat, _ velocity: CGFloat, _ width: CGFloat) {
        guard width > 0, let i = order.firstIndex(of: page) else { return }
        var step = 0                                   // +1: the page on the right, -1: the one on the left
        if abs(velocity) > 400 {
            // a flick decides, unless the fingers were flicked back the way they came (that cancels)
            if velocity * travel >= 0 || abs(travel) < 8 { step = velocity < 0 ? 1 : -1 }
        } else if abs(travel) > width * 0.4 { step = travel < 0 ? 1 : -1 }
        let target = min(max(i + step, 0), order.count - 1)
        settle(to: target, page: order[target])
    }

    var body: some View {
        ZStack {
            GeometryReader { geo in
                let o = order
                ZStack {
                    ForEach(drawnPages, id: \.self) { p in
                        pageContent(p)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .offset(x: (CGFloat(o.firstIndex(of: p) ?? 0) - pos) * geo.size.width)
                            .transition(.identity)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }

            SpectrumLayer(page: page)

            // drag the top of the player down to close it
            VStack { Color.clear.frame(height: 36).contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 20).onEnded { if $0.translation.height > 100 { close() } }); Spacer() }
            VStack {
                HStack {
                    Button { close() } label: {
                        Image(systemName: "chevron.down").font(.system(size: 16, weight: .bold)).frame(width: 46, height: 46)
                            .glass(23, interactive: true).contentShape(Circle())
                            .scaleEffect(hoverClose ? 1.08 : 1)
                    }
                    .buttonStyle(.plain).help("Close the player (Esc)")
                    .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hoverClose = h } }
                    Spacer()
                    if page == 0 { LyricsMenuButton().transition(.opacity) }
                }
                // full screen has no title bar, so the button sits as far from the top as from the side; in a window it stays below the
                // title-bar strip (that strip drags the window and swallows clicks)
                .padding(.horizontal, 20).padding(.top, isFull ? 20 : 44)
                Spacer()
                if showPill { TabPill(page: $page) }
            }
            // Esc closes the player
            Button("Close", action: close).keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0).allowsHitTesting(false)
        }
        .ignoresSafeArea()
        .background(TrackpadSwipe(onDrag: { dragged($0, $1) }, onEnd: { dragEnded($0, $1, $2) }))
        .onAppear { isFull = NSApp.keyWindow?.styleMask.contains(.fullScreen) ?? false }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in isFull = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in isFull = false }
        .onExitCommand(perform: close)
        // a tap on the pill (or the menu) changes the page: slide the strip there too
        .onChange(of: page) { newPage in
            guard let j = order.firstIndex(of: newPage), abs(pos - CGFloat(j)) > 0.001 else { return }
            settle(to: j)
        }
        .onChange(of: pageOrder) { _ in
            if let j = order.firstIndex(of: page) { pos = CGFloat(j) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .playerPage)) { n in
            if let p = n.object as? Int { withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { page = p } }
        }
    }
}

/// Follows sideways two-finger swipes on a trackpad (or a Magic Mouse) anywhere in its window, while the fingers are down.
/// onDrag: how far the fingers have travelled so far (positive: to the right) and the width of the window.
/// onEnd: the same, plus how fast they were going (points per second, positive: to the right) when they lifted.
/// It never takes clicks. Once a gesture is clearly sideways it keeps the events to itself (so nothing underneath scrolls too);
/// vertical scrolling, and anything that scrolls sideways itself (the row of albums on the Artist page), are left alone.
struct TrackpadSwipe: NSViewRepresentable {
    var onDrag: (CGFloat, CGFloat) -> Void
    var onEnd: (CGFloat, CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> Catcher { let v = Catcher(); v.onDrag = onDrag; v.onEnd = onEnd; return v }
    func updateNSView(_ v: Catcher, context: Context) { v.onDrag = onDrag; v.onEnd = onEnd }

    final class Catcher: NSView {
        var onDrag: (CGFloat, CGFloat) -> Void = { _, _ in }
        var onEnd: (CGFloat, CGFloat, CGFloat) -> Void = { _, _, _ in }
        private enum Mode { case undecided, sideways, other }
        private var mode = Mode.undecided
        private var monitor: Any?
        private var sumX: CGFloat = 0
        private var sumY: CGFloat = 0
        private var samples: [(t: TimeInterval, dx: CGFloat)] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                if let me = self, me.handle(event) { return nil }
                return event
            }
        }

        /// returns true when the event belongs to a sideways swipe and should not go any further
        private func handle(_ event: NSEvent) -> Bool {
            guard let w = window, event.window === w, event.hasPreciseScrollingDeltas else { return false }
            if event.phase.contains(.began) || event.phase.contains(.mayBegin) { sumX = 0; sumY = 0; mode = .undecided; samples = [] }
            // the glide after the fingers lift belongs to the swipe that started it
            if !event.momentumPhase.isEmpty { return mode == .sideways }
            sumX += event.scrollingDeltaX
            sumY += event.scrollingDeltaY
            if mode == .undecided {
                if overSidewaysScroller(event, in: w) { mode = .other }
                else if abs(sumX) > 8, abs(sumX) > abs(sumY) * 1.4 { mode = .sideways }
                else if abs(sumY) > 8 { mode = .other }
            }
            guard mode == .sideways else { return false }
            // with natural scrolling a positive delta is fingers moving right; with it off the sign is the other way round
            let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
            samples.append((event.timestamp, event.scrollingDeltaX * sign))
            if samples.count > 6 { samples.removeFirst() }
            let travel = sumX * sign
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                var velocity: CGFloat = 0
                if let first = samples.first, let last = samples.last, last.t > first.t {
                    velocity = samples.dropFirst().reduce(CGFloat(0)) { $0 + $1.dx } / CGFloat(last.t - first.t)
                }
                onEnd(travel, velocity, bounds.width)
            } else {
                onDrag(travel, bounds.width)
            }
            return true
        }

        /// true when the pointer is over something that scrolls sideways, which should keep the swipe for itself
        private func overSidewaysScroller(_ event: NSEvent, in w: NSWindow) -> Bool {
            guard let hit = w.contentView?.hitTest(event.locationInWindow) else { return false }
            var v: NSView? = hit
            while let cur = v {
                if let sv = cur as? NSScrollView, let doc = sv.documentView, doc.frame.width > sv.contentView.bounds.width + 2 { return true }
                v = cur.superview
            }
            return false
        }
    }
}

/// the order of the player's three pages (Lyrics 0, Current Song 1, Artist 2), kept as text like "1,0,2"
enum PlayerPages {
    static func parse(_ s: String) -> [Int] {
        var out: [Int] = []
        for p in s.split(separator: ",") { if let i = Int(p), (0...2).contains(i), !out.contains(i) { out.append(i) } }
        for i in 0...2 where !out.contains(i) { out.append(i) }
        return out
    }
    static func text(_ a: [Int]) -> String { a.map(String.init).joined(separator: ",") }
}

extension Notification.Name { static let playerPage = Notification.Name("strata.playerPage") }

/// Lyrics · Current Song · Artist: the dock's tab bar, shrunk into a pill
struct TabPill: View {
    @Binding var page: Int
    @Namespace private var ns
    private let items: [(String, String)] = [("Lyrics", "quote.bubble"), ("Current Song", "music.note"), ("Artist", "person.crop.circle")]
    @AppStorage("playerPages") private var order = "0,1,2"

    var body: some View {
        HStack(spacing: 4) {
            ForEach(PlayerPages.parse(order), id: \.self) { i in
                Button {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { page = i }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: items[i].1).font(.system(size: 16, weight: .semibold))
                        Text(items[i].0).font(.system(size: 10.5, weight: .semibold))
                    }
                    .frame(width: 98, height: 46)
                    .foregroundStyle(page == i ? Color.white : Color.white.opacity(0.6))
                    .background {
                        if page == i { Capsule().fill(Color.white.opacity(0.2)).matchedGeometryEffect(id: "bubble", in: ns) }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .glass(30, interactive: true)
        .padding(.bottom, 18)
    }
}

// MARK: - Current Song

struct SongPage: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var lib: Library
    @AppStorage("playerCover") private var coverScale = 1.0
    @AppStorage("coverShape") private var coverShape = "rounded"
    @AppStorage("coverShadow") private var coverShadow = true
    @AppStorage("coverRadius") private var coverRadius = 24.0
    @AppStorage("coverShadowAmount") private var shadowAmount = 1.0
    @AppStorage("coverPauseShrink") private var pauseShrink = true
    @AppStorage("titleSize") private var titleSize = 30.0
    @AppStorage("showAlbum") private var showAlbum = true

    var body: some View {
        if let s = player.current {
            GeometryReader { g in
                // the cover sits on the left, centred top to bottom in the window; the controls fill the rest
                let side = max(200, min(g.size.height - 240, g.size.width * 0.44, 620))
                let cover = side * CGFloat(coverScale)
                HStack(spacing: 0) {
                    CoverView(song: s, size: cover, radius: coverShape == "circle" ? cover / 2 : (coverShape == "square" ? 4 : CGFloat(coverRadius)))
                        .shadow(color: .black.opacity(coverShadow ? 0.5 * shadowAmount : 0), radius: 40, y: 22)
                        .scaleEffect(player.isPlaying || !pauseShrink ? 1 : 0.93)
                        .animation(.spring(response: 0.5, dampingFraction: 0.75), value: player.isPlaying)
                        .frame(width: side, height: side)
                        .padding(.leading, 64)
                    info(s)
                        .frame(maxWidth: 480)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 48)
                }
                .frame(width: g.size.width, height: g.size.height)
            }
        }
    }

    private func info(_ s: Song) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.title).font(.system(size: CGFloat(titleSize), weight: .heavy)).lineLimit(2)
                    Text(s.shownArtist).font(.system(size: 20, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    if showAlbum && !s.album.isEmpty { Text(s.album).font(.system(size: 14)).foregroundStyle(.white.opacity(0.5)).lineLimit(1) }
                }
                Spacer()
                Button { lib.toggleFav(s) } label: {
                    Image(systemName: lib.isFav(s) ? "heart.fill" : "heart").font(.system(size: 20)).foregroundStyle(lib.isFav(s) ? player.accent : Color.white)
                }.buttonStyle(.plain)
            }
            VStack(spacing: 4) {
                SeekBar(clock: player.clock, duration: s.duration) { player.seek(to: $0) }
                TimeLabels(clock: player.clock, duration: s.duration)
            }
            HStack {
                Spacer()
                TransportButtons(big: true)
                Spacer()
            }
            ExtraControls()
        }
    }
}

struct ExtraControls: View {
    @EnvironmentObject var player: Player
    @AppStorage("pbSpeed") private var pbSpeed = true
    @AppStorage("pbRoute") private var pbRoute = true
    @AppStorage("pbSleep") private var pbSleep = true
    @AppStorage("pbQueue") private var pbQueue = true
    @AppStorage("pbExport") private var pbExport = true
    @State private var exporting: Song?
    var body: some View {
        HStack(spacing: 22) {
            Button { player.shuffle.toggle() } label: { Image(systemName: "shuffle").foregroundStyle(player.shuffle ? player.accent : Color.white.opacity(0.7)) }
            Button { player.cycleRepeat() } label: { Image(systemName: player.repeatMode == 2 ? "repeat.1" : "repeat").foregroundStyle(player.repeatMode > 0 ? player.accent : Color.white.opacity(0.7)) }
            Spacer()
            if pbSpeed { SpeedButton().foregroundStyle(.white.opacity(0.7)) }
            if pbRoute { OutputButton(); RoutePicker().frame(width: 24, height: 24) }
            if pbSleep { SleepButton().foregroundStyle(.white.opacity(0.7)) }
            if pbQueue { QueueButton(scope: .player).foregroundStyle(.white.opacity(0.7)) }
            Image(systemName: "speaker.fill").foregroundStyle(.white.opacity(0.6))
            VolumeSlider(vol: player.vol).frame(width: 110).tint(.white)
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.white.opacity(0.6))
            if pbExport { Button { exporting = player.current } label: { Image(systemName: "square.and.arrow.up").foregroundStyle(.white.opacity(0.7)) }.help("Export this song") }
        }
        .font(.system(size: 15))
        .buttonStyle(.plain)
        .sheet(item: $exporting) { ExportSheet(song: $0) }
    }
}

// MARK: - Lyrics

struct LyricsPage: View {
    @EnvironmentObject var player: Player
    @ObservedObject var store = LyricsStore.shared
    @AppStorage("lyricsTranslate") private var translate = false
    @ObservedObject private var sync = WordSync.shared

    var body: some View {
        VStack(spacing: 0) {
            if let s = player.current {
                HStack(spacing: 14) {
                    CoverView(song: s, size: 52, radius: 10)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.title).font(.system(size: 16, weight: .bold)).lineLimit(1)
                        Text(s.shownArtist).font(.system(size: 13)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                    }
                    Spacer()
                    if store.offset != 0 { Text(String(format: "%+.2f s", store.offset)).font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.6)) }
                    if store.translating { ProgressView().controlSize(.small) }
                    if sync.busyID == s.id { HStack(spacing: 6) { ProgressView(value: sync.progress).frame(width: 54); Text("Syncing words").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)) } }
                }
                .padding(.horizontal, 60).padding(.bottom, 10)
            }
            ZStack {
                if store.markedNone {
                    VStack(spacing: 10) {
                        Image(systemName: "text.quote.slash").font(.system(size: 36))
                        Text("You marked this song as having no lyrics").font(.title3.weight(.semibold))
                        if let s = player.current { Button("Undo") { Task { await store.toggleNone(s) } }.buttonStyle(.bordered) }
                    }.foregroundStyle(.white.opacity(0.55))
                }
                else if store.synced { SyncedLyrics(store: store, clock: player.clock) }
                else if !store.plain.isEmpty {
                    ScrollView { Text(LyricsFilter.clean(store.plain)).font(.system(size: 22, weight: .semibold)).multilineTextAlignment(.leading).frame(maxWidth: 640, alignment: .leading).padding(40) }
                }
                else if store.loading { ProgressView().controlSize(.large) }
                else {
                    VStack(spacing: 10) {
                        Image(systemName: "text.quote").font(.system(size: 36))
                        Text("No lyrics found for this song").font(.title3.weight(.semibold))
                        if let s = player.current { Button("Import a lyrics file…") { Task { await store.importFile(for: s) } }.buttonStyle(.bordered) }
                    }.foregroundStyle(.white.opacity(0.55))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let s = player.current {
                VStack(spacing: 4) {
                    SeekBar(clock: player.clock, duration: s.duration) { player.seek(to: $0) }
                    TimeLabels(clock: player.clock, duration: s.duration)
                    TransportButtons().padding(.top, 2)
                }
                .frame(maxWidth: 560).padding(.horizontal, 30)
            }
        }
        .task(id: player.current?.id) { if let s = player.current { await store.ensure(s) } }
        .lyricsTranslation(store: store, on: translate)
    }
}

/// the list of lyrics redraws only when the line being sung changes; only the lit line follows the clock
struct SyncedLyrics: View {
    @ObservedObject var store: LyricsStore
    let clock: Clock
    @EnvironmentObject var player: Player
    @AppStorage("lyricsWords") private var wordMode = true
    @AppStorage("lyricsRomanize") private var romanize = false
    @AppStorage("lyricsTranslate") private var translate = false
    @AppStorage("lyricsSize") private var fontSize = 34.0
    @AppStorage("lyricsSpacing") private var lineSpacing = 14.0
    @AppStorage("lyricsWidth") private var textWidth = 720.0
    @AppStorage("lyricsAnchor") private var anchor = 0.35
    @AppStorage("lyricsFloor") private var dimFloor = 0.16
    @AppStorage("lyricsCurve") private var curve = 1.0
    @State private var st = LyricFocus()
    @State private var focus = 0.0

    private var duration: Double { (player.current?.duration ?? 0) - store.offset }

    var body: some View {
        let gaps = store.gaps(duration: duration)
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: CGFloat(lineSpacing)) {
                    Color.clear.frame(height: 120)
                    ForEach(store.lines) { l in
                        if let g = gaps[l.id] { gapRow(g, id: l.id) }
                        lineRow(l)
                    }
                    if let g = gaps[store.lines.count] { gapRow(g, id: store.lines.count) }
                    Color.clear.frame(height: 220)
                }
                .frame(maxWidth: CGFloat(textWidth))
                .padding(.horizontal, 40)
                .frame(maxWidth: .infinity)
            }
            .onReceive(clock.$position) { p in
                let f = store.focus(at: p, duration: duration)
                if f != st { st = f }
            }
            .onAppear { st = store.focus(at: clock.position, duration: duration); focus = st.target }
            .onChange(of: st) { f in
                // the wheel turns with a little bounce, and the page follows it
                withAnimation(.spring(response: 0.62, dampingFraction: 0.62)) { focus = f.target }
                withAnimation(.spring(response: 0.7, dampingFraction: 0.78)) { proxy.scrollTo(f.scrollID, anchor: UnitPoint(x: 0.5, y: anchor)) }
            }
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08), .init(color: .black, location: 0.9), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
    }

    private func gapRow(_ g: ClosedRange<Double>, id: Int) -> some View {
        GapDots(range: g, clock: clock, offset: store.offset, live: st.gap == id, playing: player.isPlaying)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(CarouselEffect(index: Double(id) - 0.5, focus: focus, lit: st.gap == id, floor: dimFloor, curve: curve))
            .id(1000 + id)
    }

    private func lineRow(_ l: LyricLine) -> some View {
        let on = st.lit(l.id)
        return VStack(alignment: .leading, spacing: 4) {
            if on && wordMode && !l.words.isEmpty {
                LiveLine(line: l, clock: clock, offset: store.offset, size: CGFloat(fontSize), playing: player.isPlaying)
                    .font(.system(size: CGFloat(fontSize), weight: .heavy))
            } else {
                LyricLineText(line: l, t: 0, active: false, words: false).font(.system(size: CGFloat(fontSize), weight: .heavy))
                    .foregroundStyle(Color.white)
            }
            if romanize, let r = LyricsFilter.romanize(l.text) { Text(LyricsFilter.clean(r)).font(.system(size: CGFloat(fontSize) * 0.56, weight: .semibold)).opacity(0.75) }
            if translate, let tr = store.translated[l.id] { Text(LyricsFilter.clean(tr)).font(.system(size: CGFloat(fontSize) * 0.56, weight: .semibold)).opacity(0.75) }
        }
        .foregroundStyle(Color.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CarouselEffect(index: Double(l.id), focus: focus, lit: on, floor: dimFloor, curve: curve))
        .contentShape(Rectangle())
        .onTapGesture { player.seek(to: l.time + store.offset) }
        .id(l.id)
    }
}

// MARK: - Artist

@MainActor
final class ArtistBio: ObservableObject {
    @Published var text = ""
    private var loaded = ""
    func load(_ name: String) async {
        guard name != loaded, name != "Unknown Artist" else { return }
        loaded = name; text = ""
        guard let enc = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let u = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(enc)") else { return }
        var req = URLRequest(url: u); req.setValue("Strata Music for Mac", forHTTPHeaderField: "User-Agent"); req.timeoutInterval = 12
        guard let (d, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        if (j["type"] as? String) == "disambiguation" { return }
        if loaded == name { text = (j["extract"] as? String) ?? "" }
    }
}

struct ArtistPage: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var lib: Library
    @StateObject private var bio = ArtistBio()

    var body: some View {
        if let s = player.current {
            let name = s.artistKey
            let artist = lib.artists.first { $0.id == name }
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 24) {
                        CoverView(song: artist?.cover ?? s, size: 150, radius: 75).shadow(color: .black.opacity(0.4), radius: 18, y: 8)
                        VStack(alignment: .leading, spacing: 10) {
                            Text(name).font(.system(size: 36, weight: .heavy)).lineLimit(2)
                            if let a = artist { Text("\(a.albums.count) albums · \(a.songs.count) songs in your library").foregroundStyle(.white.opacity(0.65)); PlayButtons(songs: a.songs) }
                        }
                        Spacer()
                    }
                    if !bio.text.isEmpty { Text(bio.text).font(.system(size: 14)).foregroundStyle(.white.opacity(0.78)).lineSpacing(3).frame(maxWidth: 680, alignment: .leading) }
                    if let a = artist, !a.albums.isEmpty {
                        Text("Albums").font(.title3.weight(.bold))
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 18) {
                                ForEach(a.albums) { al in
                                    Button { if let f = al.songs.first { player.play(f, in: al.songs) } } label: {
                                        VStack(alignment: .leading, spacing: 5) {
                                            CoverView(song: al.cover, size: 130, radius: 10)
                                            Text(al.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                        }.frame(width: 130, alignment: .leading)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    if let a = artist {
                        Text("Songs").font(.title3.weight(.bold))
                        SongRows(songs: Array(a.songs.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }.prefix(8)), showCover: true)
                    }
                }
                .padding(.horizontal, 60).padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
            .task(id: name) { await bio.load(name) }
        }
    }
}

/// the "…" button at the top right of the lyrics page: the same glass circle as the close button, on the other side
struct LyricsMenuButton: View {
    @EnvironmentObject var player: Player
    @ObservedObject private var store = LyricsStore.shared
    @ObservedObject private var sync = WordSync.shared
    @AppStorage("lyricsWords") private var wordMode = true
    @AppStorage("censorLyrics") private var censor = false
    @AppStorage("lyricsRomanize") private var romanize = false
    @AppStorage("lyricsTranslate") private var translate = false
    @State private var sharing = false
    @State private var exporting = false
    @State private var hover = false

    var body: some View {
        if let s = player.current {
            Menu {
                Button("Show lyrics earlier  (−0.25 s)") { store.nudge(-0.25, song: s) }
                Button("Show lyrics later  (+0.25 s)") { store.nudge(0.25, song: s) }
                Button("Reset sync") { store.setOffset(0, song: s) }.disabled(store.offset == 0)
                Divider()
                Toggle("Word by word", isOn: $wordMode)
                Toggle("Hide bad words", isOn: $censor)
                Toggle("Show in Latin letters", isOn: $romanize)
                if #available(macOS 15.0, *) { Toggle("Translate", isOn: $translate) }
                Divider()
                Button(store.wordSynced ? "Sync words again" : "Sync words precisely") { sync.run(s) }.disabled(sync.busyID != nil || !store.synced)
                if store.wordSynced { Button("Go back to the original timing") { Task { await store.clearAligned(s) } } }
                Button("Export a piece of this song…") { exporting = true }
                Divider()
                Button("Import a lyrics file…") { Task { await store.importFile(for: s) } }
                if store.hasOwnFile { Button("Remove my lyrics file") { Task { await store.removeOwnFile(for: s) } } }
                Button(store.markedNone ? "This song has lyrics after all" : "This song has no lyrics") { Task { await store.toggleNone(s) } }
                Divider()
                Button("Share lyrics…") { sharing = true }.disabled(store.lines.isEmpty)
                Button("Desktop lyrics") { AppWindows.open("desktoplyrics") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 16, weight: .bold)).frame(width: 46, height: 46)
                    .glass(23, interactive: true).contentShape(Circle())
                    .scaleEffect(hover ? 1.08 : 1)
            }
            .menuStyle(.borderlessButton).hideMenuIndicator().fixedSize()
            .help("Lyrics options")
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
            .sheet(isPresented: $sharing) { LyricShareSheet(song: s, lines: store.lines, plain: store.plain) }
            .sheet(isPresented: $exporting) { ExportClipSheet(song: s).environmentObject(player) }
        }
    }
}
