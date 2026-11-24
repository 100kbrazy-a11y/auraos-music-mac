import SwiftUI
import AppKit

/// the full-screen player: three pages (Lyrics, Current Song, Artist) and the little glass pill that switches them
struct FullPlayerView: View {
    @EnvironmentObject var player: Player
    var close: () -> Void
    @State private var page = 1
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

extension Notification.Name { static let playerPage = Notification.Name("strata.playerPage") }

/// Lyrics · Current Song · Artist: the dock's tab bar, shrunk into a pill
struct TabPill: View {
    @Binding var page: Int
    @Namespace private var ns
    private let items: [(String, String)] = [("Lyrics", "quote.bubble"), ("Current Song", "music.note"), ("Artist", "person.crop.circle")]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
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

    var body: some View {
        if let s = player.current {
            GeometryReader { g in
                let side = max(220, min(g.size.height - 30, g.size.width * 0.42, 560))
                HStack(spacing: 60) {
                    CoverView(song: s, size: side, radius: 24)
                        .shadow(color: .black.opacity(0.5), radius: 40, y: 22)
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
    @State private var exporting: Song?
    var body: some View {
        HStack(spacing: 22) {
            Button { player.shuffle.toggle() } label: { Image(systemName: "shuffle").foregroundStyle(player.shuffle ? player.accent : Color.white.opacity(0.7)) }
            Button { player.cycleRepeat() } label: { Image(systemName: player.repeatMode == 2 ? "repeat.1" : "repeat").foregroundStyle(player.repeatMode > 0 ? player.accent : Color.white.opacity(0.7)) }
            Spacer()
            SleepButton().foregroundStyle(.white.opacity(0.7))
            QueueButton().foregroundStyle(.white.opacity(0.7))
            Image(systemName: "speaker.fill").foregroundStyle(.white.opacity(0.6))
            Slider(value: Binding(get: { Double(player.volume) }, set: { player.volume = Float($0) }), in: 0...1).frame(width: 110).tint(.white)
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.white.opacity(0.6))
            Button { exporting = player.current } label: { Image(systemName: "square.and.arrow.up").foregroundStyle(.white.opacity(0.7)) }.help("Export this song")
        }
        .font(.system(size: 15))
        .buttonStyle(.plain)
        .sheet(item: $exporting) { ExportSheet(song: $0) }
    }
}

// MARK: - Lyrics

struct LyricsPage: View {
    @EnvironmentObject var player: Player
    @StateObject private var store = LyricsStore()

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
                }
                .padding(.horizontal, 60).padding(.bottom, 10)
            }
            ZStack {
                if store.synced { SyncedLyrics(store: store, clock: player.clock) }
                else if !store.plain.isEmpty {
                    ScrollView { Text(store.plain).font(.system(size: 22, weight: .semibold)).multilineTextAlignment(.leading).frame(maxWidth: 640, alignment: .leading).padding(40) }
                }
                else if store.loading { ProgressView().controlSize(.large) }
                else { VStack(spacing: 8) { Image(systemName: "text.quote").font(.system(size: 36)); Text("No lyrics found for this song").font(.title3.weight(.semibold)) }.foregroundStyle(.white.opacity(0.55)) }
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
        .task(id: player.current?.id) { if let s = player.current { await store.load(for: s) } }
    }
}

struct SyncedLyrics: View {
    @ObservedObject var store: LyricsStore
    @ObservedObject var clock: Clock
    @EnvironmentObject var player: Player

    private var currentIndex: Int {
        var lo = 0, hi = store.lines.count - 1, ans = -1
        let t = clock.position + 0.2
        while lo <= hi { let mid = (lo + hi) / 2; if store.lines[mid].time <= t { ans = mid; lo = mid + 1 } else { hi = mid - 1 } }
        return ans
    }

    var body: some View {
        let cur = currentIndex
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    Color.clear.frame(height: 120)
                    ForEach(store.lines) { l in
                        let on = l.id == cur
                        Text(l.text.isEmpty ? "♪" : l.text)
                            .font(.system(size: 34, weight: .heavy))
                            .foregroundStyle(Color.white.opacity(on ? 1 : (l.id < cur ? 0.28 : 0.4)))
                            .scaleEffect(on ? 1 : 0.94, anchor: .leading)
                            .blur(radius: on ? 0 : 0.6)
                            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: on)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { player.seek(to: l.time) }
                            .id(l.id)
                    }
                    Color.clear.frame(height: 220)
                }
                .frame(maxWidth: 720)
                .padding(.horizontal, 40)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: cur) { i in
                guard i >= 0 else { return }
                withAnimation(.spring(response: 0.6, dampingFraction: 0.9)) { proxy.scrollTo(i, anchor: UnitPoint(x: 0.5, y: 0.35)) }
            }
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08), .init(color: .black, location: 0.9), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
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
