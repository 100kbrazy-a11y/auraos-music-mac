import SwiftUI
import AppKit

// MARK: - the search state (shared by the YouTube page and the search box's "Search the web" button)

@MainActor
final class YouTube: ObservableObject {
    static let shared = YouTube()
    @Published var query = ""
    @Published var type = "song"                // song | album | playlist | artist
    @Published private(set) var results: [YtResult] = []
    @Published private(set) var loading = false
    @Published private(set) var error = ""
    @Published private(set) var shownQuery = ""
    /// a pasted YouTube link opens its songs straight away
    @Published var linked: YtCollection?

    func run() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        loading = true; error = ""; defer { loading = false }
        do {
            if q.contains("youtube.com/") || q.contains("youtu.be/") {
                let r = try await YtEngine.shared.tracks(link: q)
                results = []; shownQuery = q
                linked = YtCollection(kind: "link", id: q, title: r.title.isEmpty ? "YouTube link" : r.title, artist: "")
                return
            }
            let r = try await YtEngine.shared.search(q, type: type)
            results = r; shownQuery = q
            if r.isEmpty { error = "Nothing found for “\(q)” on YouTube Music." }
        } catch let e { results = []; self.error = e.localizedDescription }
    }

    /// opens the hidden browser ahead of time so the first search doesn't wait for it
    func warm() { Task { _ = try? await YtEngine.shared.use { } } }
}

struct YtCollection: Hashable { var kind: String; var id: String; var title: String; var artist: String }
struct YtArtistRef: Hashable { var id: String; var name: String }

// MARK: - small pieces

struct YtThumb: View {
    let url: String
    var size: CGFloat = 48
    var radius: CGFloat = 8
    var body: some View {
        Group {
            if let u = URL(string: url), !url.isEmpty {
                AsyncImage(url: u) { ph in
                    switch ph {
                    case .success(let i): i.resizable().aspectRatio(contentMode: .fill)
                    default: Color(white: 0.16)
                    }
                }
            } else { Color(white: 0.16).overlay(Image(systemName: "music.note").foregroundStyle(.white.opacity(0.4))) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// the little control at the end of a song row: download / progress / retry / in your library
struct DlButton: View {
    let track: Track
    var play = false
    @EnvironmentObject var lib: Library
    @EnvironmentObject var player: Player
    @ObservedObject var dl = Downloads.shared

    var body: some View {
        let song = lib.songs.first { $0.yt == track.id }
        let item = dl.items.first { $0.id == track.id }
        HStack(spacing: 10) {
            if let s = song {
                Button { player.play(s, in: [s]) } label: { Image(systemName: "play.fill") }.help("Play")
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("In your library")
            } else if let it = item, !it.failed {
                ProgressView(value: it.frac > 0 ? it.frac : nil).progressViewStyle(.circular).controlSize(.small).help(it.status)
            } else if let it = item, it.failed {
                Button { dl.retry(track.id) } label: { Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange) }.help("\(it.status). Click to try again.")
            } else {
                Button { dl.add([track], play: true) } label: { Image(systemName: "play.fill") }.help("Download and play")
                Button { dl.add([track]) } label: { Image(systemName: "arrow.down.circle") }.help("Download")
            }
        }
        .buttonStyle(.plain).font(.system(size: 17)).foregroundStyle(.primary.opacity(0.85))
    }
}

struct TrackRow: View {
    let t: Track
    var body: some View {
        HStack(spacing: 12) {
            YtThumb(url: t.thumb, size: 44, radius: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                Text([t.artist, t.album].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            DlButton(track: t)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - the YouTube page

struct YouTubeView: View {
    @ObservedObject var yt = YouTube.shared
    @EnvironmentObject var lib: Library
    @FocusState private var focus: Bool

    var body: some View {
        if let c = yt.linked {
            VStack(spacing: 0) {
                HStack { Button { yt.linked = nil } label: { Label("Back to search", systemImage: "chevron.left") }.buttonStyle(.plain).foregroundStyle(.secondary); Spacer() }
                    .padding(.horizontal, 24).padding(.top, 14)
                YtCollectionView(c: c)
            }
        } else { searchPage }
    }

    private var searchPage: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search YouTube Music, or paste a song or playlist link", text: $yt.query)
                        .textFieldStyle(.plain).font(.system(size: 15)).focused($focus)
                        .onSubmit { Task { await yt.run() } }
                    if !yt.query.isEmpty { Button { yt.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }
                    Button("Search") { Task { await yt.run() } }.buttonStyle(.borderedProminent).disabled(yt.query.trimmingCharacters(in: .whitespaces).isEmpty || yt.loading)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.08)))
                Picker("", selection: $yt.type) {
                    Text("Songs").tag("song"); Text("Albums").tag("album"); Text("Playlists").tag("playlist"); Text("Artists").tag("artist")
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
                .onChange(of: yt.type) { _ in if !yt.query.isEmpty { Task { await yt.run() } } }
            }
            .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 10)

            ZStack {
                if yt.loading { VStack(spacing: 10) { ProgressView().controlSize(.large); Text("Asking YouTube…").foregroundStyle(.secondary) } }
                else if !yt.error.isEmpty { Text(yt.error).foregroundStyle(.secondary).multilineTextAlignment(.center).padding() }
                else if yt.results.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle").font(.system(size: 48)).foregroundStyle(.secondary)
                        Text("Download music from YouTube").font(.title3.weight(.semibold))
                        Text("Search above, or paste a link. Songs are saved into your Music folder with their title, artist and cover, and show up in your library.").foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                    }
                } else {
                    List(yt.results) { r in row(r) }.scrollContentBackground(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { yt.warm(); focus = yt.results.isEmpty }
    }

    @ViewBuilder private func row(_ r: YtResult) -> some View {
        switch r.kind {
        case "song":
            TrackRow(t: Track(id: r.id, title: r.title, artist: r.artist, album: r.album, thumb: r.thumb))
        case "artist":
            NavigationLink(value: YtArtistRef(id: r.id, name: r.title)) {
                HStack(spacing: 12) {
                    YtThumb(url: r.thumb, size: 48, radius: 24)
                    VStack(alignment: .leading, spacing: 2) { Text(r.title).font(.system(size: 14, weight: .semibold)); Text(r.sub).font(.system(size: 11.5)).foregroundStyle(.secondary) }
                }.padding(.vertical, 3)
            }
        default:
            NavigationLink(value: YtCollection(kind: r.kind, id: r.id, title: r.title, artist: r.artist)) {
                HStack(spacing: 12) {
                    YtThumb(url: r.thumb, size: 48, radius: 8)
                    VStack(alignment: .leading, spacing: 2) { Text(r.title).font(.system(size: 13.5, weight: .medium)).lineLimit(1); Text(r.sub).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1) }
                }.padding(.vertical, 3)
            }
        }
    }
}

// MARK: - an album, playlist or pasted link

struct YtCollectionView: View {
    let c: YtCollection
    @State private var tracks: [Track] = []
    @State private var title = ""
    @State private var loading = true
    @State private var error = ""
    @ObservedObject var dl = Downloads.shared
    @EnvironmentObject var lib: Library

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                YtThumb(url: tracks.first?.thumb ?? "", size: 96, radius: 12)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title.isEmpty ? c.title : title).font(.system(size: 22, weight: .bold)).lineLimit(2)
                    Text(loading ? "Loading…" : "\(tracks.count) songs").foregroundStyle(.secondary)
                    HStack {
                        Button { dl.add(tracks) } label: { Label("Download all", systemImage: "arrow.down.circle.fill") }
                            .buttonStyle(.borderedProminent).disabled(tracks.isEmpty)
                        Button { dl.add(Array(tracks.prefix(1)), play: true); dl.add(Array(tracks.dropFirst())) } label: { Label("Play", systemImage: "play.fill") }
                            .buttonStyle(.bordered).disabled(tracks.isEmpty)
                    }
                }
                Spacer()
            }
            .padding(24)
            if !error.isEmpty { Text(error).foregroundStyle(.orange).padding(.horizontal, 24) }
            List(tracks) { t in TrackRow(t: t) }.scrollContentBackground(.hidden)
                .overlay { if loading { ProgressView().controlSize(.large) } }
        }
        .navigationTitle(title.isEmpty ? c.title : title)
        .task(id: c.id) {
            loading = true; error = ""
            do {
                let r = c.kind == "link" ? try await YtEngine.shared.tracks(link: c.id) : try await YtEngine.shared.tracks(kind: c.kind, id: c.id, artist: c.artist)
                tracks = r.tracks; title = r.title
                if r.tracks.isEmpty { error = "No songs found here." }
            } catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}

// MARK: - an artist's page on YouTube Music

struct YtArtistView: View {
    let a: YtArtistRef
    @State private var page: YtEngine.ArtistPage?
    @State private var loading = true
    @State private var error = ""
    @ObservedObject var dl = Downloads.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 18) {
                    YtThumb(url: page?.thumb ?? "", size: 110, radius: 55)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(page?.name.isEmpty == false ? page!.name : a.name).font(.system(size: 28, weight: .bold))
                        if let p = page, !p.top.isEmpty { Button { dl.add(p.top) } label: { Label("Download top songs", systemImage: "arrow.down.circle.fill") }.buttonStyle(.borderedProminent) }
                    }
                    Spacer()
                }
                if loading { ProgressView().controlSize(.large).frame(maxWidth: .infinity) }
                if !error.isEmpty { Text(error).foregroundStyle(.orange) }
                if let p = page {
                    if !p.top.isEmpty {
                        Text("Top songs").font(.title3.weight(.bold))
                        VStack(spacing: 0) { ForEach(p.top) { t in TrackRow(t: t); Divider().opacity(0.3) } }
                    }
                    if !p.albums.isEmpty {
                        Text("Albums, singles and EPs").font(.title3.weight(.bold))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 18, alignment: .top)], alignment: .leading, spacing: 20) {
                            ForEach(p.albums) { al in
                                NavigationLink(value: YtCollection(kind: "album", id: al.id, title: al.title, artist: p.name)) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        YtThumb(url: al.thumb, size: 150, radius: 10)
                                        Text(al.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                                        Text(al.sub).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                    }.frame(width: 150, alignment: .leading)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(24).padding(.bottom, 80)
        }
        .navigationTitle(a.name)
        .task(id: a.id) {
            loading = true; error = ""
            do { page = try await YtEngine.shared.artist(a.id) } catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}

// MARK: - the download manager page

struct DownloadsView: View {
    @ObservedObject var dl = Downloads.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(dl.active > 0 ? "\(dl.active) downloading" : "Nothing downloading").foregroundStyle(.secondary)
                Spacer()
                if dl.items.contains(where: { $0.done || $0.failed }) { Button("Clear finished") { dl.clearFinished() } }
                if dl.active > 0 { Button("Cancel all", role: .destructive) { dl.cancelAll() } }
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
            if dl.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 46)).foregroundStyle(.secondary)
                    Text("No downloads yet").font(.title3.weight(.semibold))
                    Text("Songs you download from YouTube show up here with their progress.").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(dl.items) { it in
                    HStack(spacing: 12) {
                        YtThumb(url: it.track.thumb, size: 44, radius: 7)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(it.track.title.isEmpty ? it.track.id : it.track.title).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                            if !it.done && !it.failed && it.frac > 0 { ProgressView(value: it.frac) }
                            Text(statusLine(it)).font(.system(size: 11.5)).foregroundStyle(it.failed ? Color.orange : Color.secondary).lineLimit(1)
                        }
                        Spacer()
                        if it.failed { Button { dl.retry(it.id) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("Try again") }
                        if it.done { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        else { Button { dl.cancel(it.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).help("Cancel") }
                    }
                    .padding(.vertical, 3)
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func statusLine(_ it: DlItem) -> String {
        if it.done || it.failed || it.frac == 0 { return [it.track.artist, it.status].filter { !$0.isEmpty }.joined(separator: " · ") }
        let mb = Double(it.bytes) / 1_000_000, total = Double(it.size) / 1_000_000
        var s = String(format: "%.1f of %.1f MB", mb, total)
        if it.speed > 0 { s += String(format: " · %.1f MB/s", it.speed / 1_000_000) }
        return s
    }
}
