import SwiftUI
import AppKit

/// the full-screen player: three pages (Lyrics, Current Song, Artist) and the little glass pill that switches them
struct FullPlayerView: View {
    @EnvironmentObject var player: Player
    var close: () -> Void
    @State private var page = UserDefaults.standard.object(forKey: "playerStart") as? Int ?? 1
    @State private var hoverClose = false

    var body: some View {
        ZStack {
            Group {
                switch page {
                case 0: LyricsPage()
                case 2: ArtistPage()
                default: SongPage()
                }
            }
            .id(page)
            .transition(.opacity.combined(with: .scale(scale: 0.985)))
            .padding(.top, 96).padding(.bottom, 92)

            VStack {
                Spacer()
                SpectrumView(height: 110).opacity(page == 0 ? 0.25 : 0.55).padding(.horizontal, 40).padding(.bottom, 80)
            }.allowsHitTesting(false)

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
                }
                // below the window's title-bar strip (that strip drags the window and swallows clicks) and clear of the traffic lights
                .padding(.leading, 20).padding(.trailing, 22).padding(.top, 40)
                Spacer()
                TabPill(page: $page)
            }
            // drag the top of the player down to close it
            VStack { Color.clear.frame(height: 36).contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 20).onEnded { if $0.translation.height > 100 { close() } }); Spacer() }
            // Esc closes the player
            Button("Close", action: close).keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0).allowsHitTesting(false)
        }
        .onExitCommand(perform: close)
        .onReceive(NotificationCenter.default.publisher(for: .playerPage)) { n in
            if let p = n.object as? Int { withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { page = p } }
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

    var body: some View {
        if let s = player.current {
            GeometryReader { g in
                let side = max(220, min(g.size.height - 30, g.size.width * 0.42, 560))
                HStack(spacing: 60) {
                    CoverView(song: s, size: side * CGFloat(coverScale), radius: coverShape == "circle" ? side * CGFloat(coverScale) / 2 : (coverShape == "square" ? 4 : 24))
                        .shadow(color: .black.opacity(coverShadow ? 0.5 : 0), radius: 40, y: 22)
                        .scaleEffect(player.isPlaying ? 1 : 0.93)
                        .animation(.spring(response: 0.5, dampingFraction: 0.75), value: player.isPlaying)
                    VStack(alignment: .leading, spacing: 18) {
                        Spacer(minLength: 0)
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(s.title).font(.system(size: 30, weight: .heavy)).lineLimit(2)
                                Text(s.shownArtist).font(.system(size: 20, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                                if !s.album.isEmpty { Text(s.album).font(.system(size: 14)).foregroundStyle(.white.opacity(0.5)).lineLimit(1) }
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
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: 440)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 40)
            }
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
            Slider(value: Binding(get: { Double(player.volume) }, set: { player.volume = Float($0) }), in: 0...1).frame(width: 110).tint(.white)
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
    @Environment(\.openWindow) private var openWindow
    @AppStorage("lyricsWords") private var wordMode = true
    @AppStorage("censorLyrics") private var censor = false
    @AppStorage("lyricsRomanize") private var romanize = false
    @AppStorage("lyricsTranslate") private var translate = false
    @State private var sharing = false

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
                    menu(s)
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
        .sheet(isPresented: $sharing) {
            if let s = player.current { LyricShareSheet(song: s, lines: store.lines, plain: store.plain) }
        }
    }

    private func menu(_ s: Song) -> some View {
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
            Button("Import a lyrics file…") { Task { await store.importFile(for: s) } }
            if store.hasOwnFile { Button("Remove my lyrics file") { Task { await store.removeOwnFile(for: s) } } }
            Button(store.markedNone ? "This song has lyrics after all" : "This song has no lyrics") { Task { await store.toggleNone(s) } }
            Divider()
            Button("Share lyrics…") { sharing = true }.disabled(store.lines.isEmpty)
            Button("Desktop lyrics") { openWindow(id: "desktoplyrics") }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 18)).foregroundStyle(.white.opacity(0.7))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 30)
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
    @State private var cur = -1

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    Color.clear.frame(height: 120)
                    ForEach(store.lines) { l in
                        let on = l.id == cur
                        VStack(alignment: .leading, spacing: 4) {
                            if on && wordMode && !l.words.isEmpty {
                                LiveLine(line: l, clock: clock, offset: store.offset).font(.system(size: 34, weight: .heavy))
                            } else {
                                LyricLineText(line: l, t: 0, active: false, words: false).font(.system(size: 34, weight: .heavy))
                            }
                            if romanize, let r = LyricsFilter.romanize(l.text) { Text(LyricsFilter.clean(r)).font(.system(size: 19, weight: .semibold)).opacity(0.75) }
                            if translate, let tr = store.translated[l.id] { Text(LyricsFilter.clean(tr)).font(.system(size: 19, weight: .semibold)).opacity(0.75) }
                        }
                        .foregroundStyle(Color.white.opacity(on ? 1 : (l.id < cur ? 0.28 : 0.4)))
                        .scaleEffect(on ? 1 : 0.94, anchor: .leading)
                        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: on)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { player.seek(to: l.time + store.offset) }
                        .id(l.id)
                    }
                    Color.clear.frame(height: 220)
                }
                .frame(maxWidth: 720)
                .padding(.horizontal, 40)
                .frame(maxWidth: .infinity)
            }
            .onReceive(clock.$position) { p in
                let i = store.index(at: p)
                if i != cur { cur = i }
            }
            .onAppear { cur = store.index(at: clock.position) }
            .onChange(of: cur) { i in
                guard i >= 0 else { return }
                withAnimation(.spring(response: 0.6, dampingFraction: 0.9)) { proxy.scrollTo(i, anchor: UnitPoint(x: 0.5, y: 0.35)) }
            }
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08), .init(color: .black, location: 0.9), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
    }
}

/// the line being sung, lit word by word
private struct LiveLine: View {
    let line: LyricLine
    @ObservedObject var clock: Clock
    let offset: Double
    var body: some View { LyricLineText(line: line, t: clock.position + 0.2 - offset, active: true, words: true) }
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
