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
                CachedThumb(url: u, pixels: Int(size * 2))
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
                    Spacer()
                    Button { ArtistGrab.shared.start(id: r.id, name: r.title) } label: { Image(systemName: "arrow.down.circle").font(.system(size: 17)) }
                        .buttonStyle(.plain).help("Download everything by \(r.title)")
                }.padding(.vertical, 3)
            }
            .grabMenu(r.id, r.title)
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
                        HStack {
                            Button { ArtistGrab.shared.start(id: a.id, name: page?.name ?? a.name) } label: { Label("Download everything", systemImage: "arrow.down.circle.fill") }
                                .buttonStyle(.borderedProminent).disabled(ArtistGrab.shared.busy)
                            if let p = page, !p.top.isEmpty { Button { dl.add(p.top) } label: { Label("Top songs", systemImage: "star") }.buttonStyle(.bordered) }
                        }
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
                Text("·  \(dl.finished) downloaded").foregroundStyle(.secondary)
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
                List {
                  ForEach(dl.items.filter { !$0.done }) { it in row(it) }
                  let doneItems = dl.items.filter { $0.done }
                  if !doneItems.isEmpty {
                    Section("Downloaded") { ForEach(doneItems) { it in row(it) } }
                  }
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    @ViewBuilder private func row(_ it: DlItem) -> some View {
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

    private func statusLine(_ it: DlItem) -> String {
        if it.done || it.failed || it.frac == 0 { return [it.track.artist, it.status].filter { !$0.isEmpty }.joined(separator: " · ") }
        let mb = Double(it.bytes) / 1_000_000, total = Double(it.size) / 1_000_000
        var s = String(format: "%.1f of %.1f MB", mb, total)
        if it.speed > 0 { s += String(format: " · %.1f MB/s", it.speed / 1_000_000) }
        return s
    }
}

// MARK: - "download everything" for an artist

@MainActor
final class ArtistGrab: ObservableObject {
    static let shared = ArtistGrab()
    struct Pending: Identifiable {
        let id = UUID(); var name: String
        var everything: [Track]; var albumsOnly: [Track]; var releases: Int
    }
    @Published private(set) var status = ""          // "Reading release 3 of 14…" while it works
    @Published var pending: Pending?
    @Published var error = ""
    private var task: Task<Void, Never>?

    var busy: Bool { !status.isEmpty }

    nonisolated private func key(_ title: String, _ artist: String) -> String { title.lowercased() + "|" + primaryArtist(artist).lowercased() }

    func start(id: String, name: String) {
        guard !busy else { return }
        error = ""; status = "Reading \(name)…"
        task = Task {
            defer { status = "" }
            do {
                let page = try await YtEngine.shared.artist(id)
                var seen = Set<String>(); var all: [Track] = []; var albums: [Track] = []
                for (i, al) in page.albums.enumerated() {
                    try Task.checkCancellation()
                    status = "Reading release \(i + 1) of \(page.albums.count)…"
                    guard let r = try? await YtEngine.shared.tracks(kind: "album", id: al.id, artist: page.name) else { continue }
                    for t in r.tracks where seen.insert(t.id).inserted { all.append(t); if al.sub.hasPrefix("Album") { albums.append(t) } }
                }
                for t in page.top where seen.insert(t.id).inserted { all.append(t) }
                // leave out what's already in the library
                let lib = Downloads.shared.lib
                let haveIDs = Set(lib?.songs.compactMap { $0.yt } ?? [])
                let haveKeys = Set(lib?.songs.map { key($0.title, $0.artist) } ?? [])
                func fresh(_ l: [Track]) -> [Track] { l.filter { !haveIDs.contains($0.id) && !haveKeys.contains(key($0.title, $0.artist)) } }
                let e = fresh(all)
                if e.isEmpty { error = all.isEmpty ? "YouTube Music has no songs listed for \(page.name)." : "Everything by \(page.name) that YouTube lists is already in your library." }
                else { pending = Pending(name: page.name.isEmpty ? name : page.name, everything: e, albumsOnly: fresh(albums), releases: page.albums.count) }
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }

    func cancel() { task?.cancel() }
}

struct ArtistGrabPrompt: View {
    @ObservedObject var grab = ArtistGrab.shared
    @State private var albumsOnly = false

    var body: some View {
        ZStack {
            if let p = grab.pending {
                Color.black.opacity(0.45).ignoresSafeArea().onTapGesture { grab.pending = nil }.transition(.opacity)
                VStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.arrow.down").font(.system(size: 38)).foregroundStyle(.secondary)
                    let n = albumsOnly ? p.albumsOnly.count : p.everything.count
                    Text("Download \(n) songs?").font(.system(size: 19, weight: .bold))
                    Text("\(p.name) has \(p.releases) releases on YouTube Music. Songs you already have are left out.").font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Toggle("Albums only (no singles)", isOn: $albumsOnly).toggleStyle(.checkbox)
                    HStack(spacing: 10) {
                        Button("Not now") { grab.pending = nil }.buttonStyle(.bordered)
                        Button("Download all") { Downloads.shared.add(albumsOnly ? p.albumsOnly : p.everything); grab.pending = nil }
                            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(n == 0)
                    }.controlSize(.large).padding(.top, 4)
                }
                .padding(24).frame(width: 340).glass(26).shadow(color: .black.opacity(0.35), radius: 30, y: 12)
                .transition(.scale(scale: 0.94).combined(with: .opacity))
            } else if !grab.error.isEmpty {
                Color.black.opacity(0.45).ignoresSafeArea().onTapGesture { grab.error = "" }.transition(.opacity)
                VStack(spacing: 12) {
                    Text(grab.error).font(.system(size: 13)).multilineTextAlignment(.center)
                    Button("OK") { grab.error = "" }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
                .padding(24).frame(width: 320).glass(26)
            }
            if grab.busy {
                VStack {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(grab.status).font(.system(size: 12, weight: .medium))
                        Button("Cancel") { grab.cancel() }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8).glass(16).padding(.top, 10)
                    Spacer()
                }.transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: grab.pending?.id)
        .animation(.easeOut(duration: 0.2), value: grab.busy)
    }
}

extension View {
    /// "Download everything" for a YouTube artist
    func grabMenu(_ id: String, _ name: String) -> some View {
        contextMenu { Button("Download Everything by \(name)") { ArtistGrab.shared.start(id: id, name: name) } }
    }
}

/// downloads a web picture once, shrinks it to the size it's shown at, and remembers it
enum WebImage {
    static let cache: NSCache<NSString, NSImage> = { let c = NSCache<NSString, NSImage>(); c.countLimit = 400; return c }()
    static func key(_ u: URL, _ px: Int) -> NSString { "\(u.absoluteString)|\(px)" as NSString }

    static func load(_ u: URL, pixels px: Int) async -> NSImage? {
        let k = key(u, px)
        if let c = cache.object(forKey: k) { return c }
        let out: NSImage? = await Task.detached(priority: .utility) { () -> NSImage? in
            var req = URLRequest(url: u, timeoutInterval: 20)
            req.setValue("StrataMusic/2 (macOS music app)", forHTTPHeaderField: "User-Agent")
            guard let (d, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200,
                  let src = CGImageSourceCreateWithData(d as CFData, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: px] as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if let out = out { cache.setObject(out, forKey: k) }
        return out
    }
}

struct CachedThumb: View {
    let url: URL
    let pixels: Int
    @State private var img: NSImage?

    var body: some View {
        Group {
            if let i = img ?? WebImage.cache.object(forKey: WebImage.key(url, pixels)) { Image(nsImage: i).resizable().aspectRatio(contentMode: .fill) }
            else { Color(white: 0.16) }
        }
        .task(id: url) { img = await WebImage.load(url, pixels: pixels) }
    }
}

/// a wide picture that tries each address in turn (the first one that loads is used) and shows [fallback] while loading or if none do
struct BannerImage<Fallback: View>: View {
    let urls: [String]
    @ViewBuilder var fallback: () -> Fallback
    @State private var img: NSImage?

    var body: some View {
        ZStack {
            fallback()
            if let img = img { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).transition(.opacity) }
        }
        .task(id: urls) {
            img = nil
            for s in urls {
                guard let u = URL(string: s) else { continue }
                if let i = await WebImage.load(u, pixels: 1600) { withAnimation(.easeOut(duration: 0.25)) { img = i }; return }
            }
        }
    }
}
