import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - listening history (for Replay)

/// one line per song played: which song, when, and how long it is. Kept in history.json.
final class PlayLog: @unchecked Sendable {
    static let shared = PlayLog()
    struct Entry: Codable { var s: String; var t: Double; var d: Double }

    private let lock = NSLock()
    private var all: [Entry] = []
    private var saver: Task<Void, Never>?
    private let url = Disk.dir.appendingPathComponent("history.json")

    init() {
        if let d = try? Data(contentsOf: url), let e = try? JSONDecoder().decode([Entry].self, from: d) { all = e }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in self?.flush() }
    }

    var entries: [Entry] { lock.lock(); defer { lock.unlock() }; return all }

    func add(_ song: Song) {
        lock.lock()
        all.append(Entry(s: song.id, t: Date().timeIntervalSince1970, d: song.duration))
        if all.count > 200_000 { all.removeFirst(all.count - 200_000) }
        lock.unlock()
        saver?.cancel()
        saver = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled { self?.flush(wait: false) }
        }
    }

    /// writes the history; when [wait] is false the encoding happens away from the main thread
    func flush(wait: Bool = true) {
        let snapshot = entries, target = url
        let work = { if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: target, options: .atomic) } }
        if wait { work() } else { DispatchQueue.global(qos: .utility).async(execute: work) }
    }
}

// MARK: - radio

/// "Start Radio": plays a song, then keeps two more songs queued from YouTube Music's similar songs.
/// Songs you already own play right away; the others are downloaded just ahead of time.
@MainActor
final class Radio: ObservableObject {
    static let shared = Radio()
    @Published private(set) var active = false
    @Published private(set) var loading = false
    @Published private(set) var title = ""
    @Published private(set) var ids = Set<String>()      // the library songs radio has queued

    private var feed: Task<Void, Never>?
    private var seen = Set<String>()

    func start(from song: Song) {
        stop()
        guard let lib = Library.main else { return }
        Downloads.shared.lib = lib
        active = true; title = song.title + " Radio"; ids = [song.id]; seen = [song.yt ?? ""]
        Player.shared.play(song, in: [song])
        lib.flash("Starting radio from “\(song.title)”")
        feed = Task { [weak self] in await self?.run(seed: song) }
    }

    func start(artist name: String) {
        guard let lib = Library.main, let a = lib.artists.first(where: { $0.id == name }) else { return }
        if let s = a.songs.max(by: { ($0.plays ?? 0) < ($1.plays ?? 0) }) { start(from: s) }
    }

    func start(album a: AlbumInfo) { if let s = a.songs.first { start(from: s) } }

    func stop() {
        feed?.cancel(); feed = nil
        active = false; loading = false; ids = []
    }

    private func find(_ t: Track) -> Song? {
        guard let lib = Library.main else { return nil }
        if let s = lib.songs.first(where: { $0.yt == t.id }) { return s }
        let title = t.title.lowercased(), artist = primaryArtist(t.artist).lowercased()
        return lib.songs.first { $0.title.lowercased() == title && primaryArtist($0.artist).lowercased() == artist }
    }

    private func waitFor(_ t: Track) async -> Song? {
        for _ in 0..<150 {
            if Task.isCancelled || !active { return nil }
            if let s = Library.main?.songs.first(where: { $0.yt == t.id }) { return s }
            if let it = Downloads.shared.items.first(where: { $0.id == t.id }), it.failed { return nil }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
        }
        return nil
    }

    private func run(seed: Song) async {
        let player = Player.shared
        var last = seed
        var pending: [Track] = []
        var failures = 0
        while !Task.isCancelled && active {
            // somebody picked something else: radio's done
            if let cur = player.current, !ids.contains(cur.id) { stop(); return }
            let ahead = max(0, player.queue.count - player.index - 1)
            if ahead >= 2 { try? await Task.sleep(nanoseconds: 2_000_000_000); continue }
            if pending.isEmpty {
                loading = true
                let got = try? await YtEngine.shared.radio(id: last.yt, q: "\(last.title) \(last.artist)")
                loading = false
                if Task.isCancelled || !active { return }
                pending = (got ?? []).filter { !seen.contains($0.id) }
                if pending.isEmpty {
                    failures += 1
                    if failures >= 3 { Library.main?.flash("Radio couldn't find more songs"); stop(); return }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    continue
                }
                failures = 0
            }
            let t = pending.removeFirst()
            seen.insert(t.id)
            if let s = find(t) {
                ids.insert(s.id); player.enqueue(s); last = s
                continue
            }
            Downloads.shared.add([t])
            if let s = await waitFor(t), active { ids.insert(s.id); player.enqueue(s); last = s }
        }
    }
}

// MARK: - new releases from the artists you play

struct NewRelease: Codable, Identifiable, Hashable {
    var id: String; var title: String; var artist: String; var thumb: String; var year: String
}

@MainActor
final class NewReleases: ObservableObject {
    static let shared = NewReleases()
    @Published private(set) var items: [NewRelease] = []
    @Published private(set) var checking = false
    @Published private(set) var lastCheck: Date?

    init() {
        if let d = UserDefaults.standard.data(forKey: "newReleases"), let e = try? JSONDecoder().decode([NewRelease].self, from: d) { items = e }
        let t = UserDefaults.standard.double(forKey: "newReleasesAt")
        if t > 0 { lastCheck = Date(timeIntervalSince1970: t) }
    }

    func refresh(lib: Library, force: Bool = false) async {
        guard !checking else { return }
        if !force {
            if let l = lastCheck, Date().timeIntervalSince(l) < 7 * 86400 { return }
            if UserDefaults.standard.object(forKey: "homeReleases") as? Bool == false { return }
        }
        guard !lib.songs.isEmpty else { return }
        checking = true; defer { checking = false }
        let artists = Array(Home.topArtists(lib).prefix(8))
        var ids = (UserDefaults.standard.dictionary(forKey: "ytArtistIDs") as? [String: String]) ?? [:]
        let year = Calendar.current.component(.year, from: Date())
        var found: [NewRelease] = []
        var ok = 0
        for a in artists {
            do {
                var id = ids[a.id]
                if id == nil {
                    let r = try await YtEngine.shared.search(a.id, type: "artist")
                    id = r.first(where: { $0.kind == "artist" })?.id ?? r.first?.id
                    if let i = id { ids[a.id] = i }
                }
                guard let aid = id else { continue }
                let page = try await YtEngine.shared.artist(aid)
                ok += 1
                for al in page.albums {
                    let tail = al.sub.split(separator: "·").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    let y = Int(tail) ?? 0
                    guard y >= year - 1 else { continue }
                    if lib.albums.contains(where: { $0.title.caseInsensitiveCompare(al.title) == .orderedSame }) { continue }
                    found.append(NewRelease(id: al.id, title: al.title, artist: a.id, thumb: al.thumb, year: String(y)))
                }
            } catch { continue }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        UserDefaults.standard.set(ids, forKey: "ytArtistIDs")
        guard ok > 0 else { return }
        items = found.sorted { $0.year > $1.year }
        lastCheck = Date()
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: "newReleases") }
        UserDefaults.standard.set(lastCheck!.timeIntervalSince1970, forKey: "newReleasesAt")
    }
}

// MARK: - artist photos and bios (Wikipedia)

@MainActor
final class ArtistProfiles: ObservableObject {
    static let shared = ArtistProfiles()
    struct Profile: Codable { var bio: String; var photo: String; var blurb: String; var alt: [String]? = nil }
    @Published private(set) var cache: [String: Profile] = [:]
    private var tried = Set<String>()

    init() {
        UserDefaults.standard.removeObject(forKey: "artistProfiles")      // the first version stored pictures that often didn't load
        if let d = UserDefaults.standard.data(forKey: "artistProfiles2"), let e = try? JSONDecoder().decode([String: Profile].self, from: d) { cache = e }
    }

    func load(_ name: String) async {
        guard cache[name] == nil, !tried.contains(name), !name.isEmpty, name != "Unknown Artist" else { return }
        tried.insert(name)
        var found: Profile?
        for cand in [name, name + " (musician)", name + " (band)", name + " (singer)", name + " (rapper)"] {
            if let p = await Self.fetch(cand) { found = p; break }
        }
        let deezer = await Self.deezer(name)
        if var p = found {
            if let d = deezer { p.alt = (p.alt ?? []) + [d] }
            cache[name] = p; save()
        } else if let d = deezer {
            cache[name] = Profile(bio: "", photo: d, blurb: "")
            save()
        }
    }

    private func save() { if let d = try? JSONEncoder().encode(cache) { UserDefaults.standard.set(d, forKey: "artistProfiles2") } }

    /// Deezer's picture of the artist, for artists Wikipedia has no photo of
    private nonisolated static func deezer(_ name: String) async -> String? {
        var c = URLComponents(string: "https://api.deezer.com/search/artist")!
        c.queryItems = [URLQueryItem(name: "q", value: name), URLQueryItem(name: "limit", value: "5")]
        guard let u = c.url, let (d, _) = try? await URLSession.shared.data(from: u),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let list = j["data"] as? [[String: Any]] else { return nil }
        func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let f = fold(name)
        guard let hit = list.first(where: { fold(($0["name"] as? String) ?? "") == f }) else { return nil }
        let pic = (hit["picture_xl"] as? String) ?? (hit["picture_big"] as? String) ?? ""
        return pic.isEmpty || pic.contains("/artist//") ? nil : pic     // Deezer's grey placeholder has an empty id in its address
    }

    private nonisolated static func fetch(_ title: String) async -> Profile? {
        let slug = title.replacingOccurrences(of: " ", with: "_")
        guard let enc = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))),
              let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(enc)") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("StrataMusic/1.5 (macOS music app)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], (j["type"] as? String) == "standard" else { return nil }
        let desc = (j["description"] as? String) ?? ""
        let extract = (j["extract"] as? String) ?? ""
        let music = "singer|rapper|musician|band|group|songwriter|record producer|disc jockey|DJ|composer|vocalist|duo|trio|pianist|guitarist|drummer|music"
        guard desc.range(of: music, options: [.regularExpression, .caseInsensitive]) != nil || extract.prefix(300).range(of: "(singer|rapper|musician|band|songwriter|composer)", options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        let thumb = ((j["thumbnail"] as? [String: Any])?["source"] as? String) ?? ""
        var photo = thumb
        // a bigger copy is only asked for when the original is big enough (Wikipedia refuses to enlarge a picture)
        let originalWidth = ((j["originalimage"] as? [String: Any])?["width"] as? Int) ?? 0
        if originalWidth >= 1000, let r = photo.range(of: "/\\d+px-", options: .regularExpression), photo.contains("/thumb/") { photo.replaceSubrange(r, with: "/1000px-") }
        return Profile(bio: extract, photo: photo, blurb: desc, alt: thumb.isEmpty || thumb == photo ? nil : [thumb])
    }
}

// MARK: - the Home page

@MainActor
enum Home {
    static func plays(_ a: ArtistInfo) -> Int { a.songs.reduce(0) { $0 + ($1.plays ?? 0) } }
    static func topArtists(_ lib: Library) -> [ArtistInfo] {
        lib.artists.filter { $0.id != "Unknown Artist" }.sorted { (plays($0), $0.songs.count) > (plays($1), $1.songs.count) }
    }
}

/// what the Home page shows, worked out once per change of the library rather than every time anything redraws
struct HomeData {
    var jumpBack: [Song] = []
    var forgotten: [AlbumInfo] = []
    var topSongs: [Song] = []
    var artists: [ArtistInfo] = []
    var recentAlbums: [AlbumInfo] = []
    var favs: [Song] = []
    var unplayed: [Song] = []
    var freshCover: Song?

    @MainActor static func build(_ lib: Library) -> HomeData {
        var d = HomeData()
        var seen = Set<String>()
        for s in lib.songs.filter({ $0.lastPlayed != nil }).sorted(by: { ($0.lastPlayed ?? 0) > ($1.lastPlayed ?? 0) }) {
            if seen.insert(s.albumKey).inserted { d.jumpBack.append(s) }
            if d.jumpBack.count >= 12 { break }
        }
        if d.jumpBack.isEmpty { d.jumpBack = Array(lib.recentSongs.prefix(12)) }
        let cutoff = Date().timeIntervalSince1970 - 30 * 86400
        func total(_ a: AlbumInfo) -> Int { a.songs.reduce(0) { $0 + ($1.plays ?? 0) } }
        d.forgotten = Array(lib.albums.filter { a in total(a) >= 3 && (a.songs.compactMap { $0.lastPlayed }.max() ?? 0) < cutoff }.sorted { total($0) > total($1) }.prefix(12))
        d.topSongs = lib.songs.filter { ($0.plays ?? 0) > 0 }.sorted { ($0.plays ?? 0) > ($1.plays ?? 0) }
        d.artists = Array(Home.topArtists(lib).prefix(14))
        d.recentAlbums = Array(lib.albums.sorted { ($0.songs.map { $0.added }.max() ?? 0) > ($1.songs.map { $0.added }.max() ?? 0) }.prefix(12))
        d.favs = lib.favoriteSongs
        d.unplayed = lib.songs.filter { ($0.plays ?? 0) == 0 }
        d.freshCover = d.unplayed.randomElement()
        return d
    }
}

struct HomeView: View {
    @EnvironmentObject var lib: Library
    @EnvironmentObject var player: Player
    @ObservedObject var radio = Radio.shared
    @ObservedObject var rel = NewReleases.shared

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 5 ? "Still up?" : h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
    }

    var body: some View {
        if lib.songs.isEmpty { EmptyLibrary() } else { page }
    }

    @State private var d = HomeData()
    private func refresh() { d = HomeData.build(lib) }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Text(greeting).font(.system(size: 30, weight: .bold))
                shelf("Jump back in") {
                    ForEach(d.jumpBack) { s in
                        HomeSongCard(song: s) { player.play(s, in: d.jumpBack) }
                    }
                }
                mixes
                let artists = d.artists
                if !artists.isEmpty {
                    shelf("Your artists") {
                        ForEach(artists) { a in
                            NavigationLink(value: ArtistRef(name: a.id)) {
                                VStack(spacing: 6) {
                                    CoverView(song: a.cover, size: 130, radius: 65).shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                                    Text(a.id).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).frame(width: 130)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
                releases
                if !d.forgotten.isEmpty {
                    shelf("It's been a while") { ForEach(d.forgotten) { AlbumCard(a: $0, size: 150) } }
                }
                shelf("Recently added") {
                    ForEach(d.recentAlbums) { AlbumCard(a: $0, size: 150) }
                }
            }
            .padding(24).padding(.bottom, 90)
        }
        .onAppear(perform: refresh)
        .onChange(of: lib.revision) { _ in refresh() }
        .task {
            await rel.refresh(lib: lib)
        }
    }

    @ViewBuilder private var mixes: some View {
        let tops = Array(d.topSongs.prefix(3))
        let favs = d.favs
        let unplayed = d.unplayed
        shelf("Made for you") {
            ForEach(tops) { s in
                MixTile(title: s.title + " Radio", sub: "More like \(s.shownArtist)", cover: s, icon: "dot.radiowaves.left.and.right", tint: player.accent) { radio.start(from: s) }
            }
            if favs.count >= 5 {
                MixTile(title: "Favorites Mix", sub: "\(favs.count) songs you love", cover: favs.first, icon: "heart.fill", tint: .pink) { player.playAll(favs, shuffled: true) }
            }
            if d.topSongs.count >= 5 {
                MixTile(title: "On Repeat", sub: "Your most played", cover: d.topSongs.first, icon: "repeat", tint: .orange) { player.playAll(Array(d.topSongs.prefix(30)), shuffled: false) }
            }
            if unplayed.count >= 5 {
                MixTile(title: "Fresh Picks", sub: "Songs you haven't played yet", cover: d.freshCover, icon: "sparkles", tint: .teal) { player.playAll(Array(unplayed.shuffled().prefix(40)), shuffled: false) }
            }
        }
    }

    @ViewBuilder private var releases: some View {
        if !rel.items.isEmpty || rel.checking {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("New from your artists").font(.title3.weight(.bold))
                    if rel.checking { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Check now") { Task { await rel.refresh(lib: lib, force: true) } }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(rel.checking)
                }
                if rel.items.isEmpty {
                    Text("Looking at your top artists on YouTube Music…").foregroundStyle(.secondary).font(.callout)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 18) {
                            ForEach(rel.items) { r in
                                NavigationLink(value: YtCollection(kind: "album", id: r.id, title: r.title, artist: r.artist)) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        YtThumb(url: r.thumb, size: 150, radius: 10).shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                                        Text(r.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                        Text(r.artist + " · " + r.year).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                    }.frame(width: 150, alignment: .leading)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        } else {
            HStack {
                Button { Task { await rel.refresh(lib: lib, force: true) } } label: { Label("Look for new releases from your artists", systemImage: "sparkle.magnifyingglass") }.buttonStyle(.bordered)
            }
        }
    }

    private func shelf<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.bold))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 18) { content() }.padding(.vertical, 4)
            }
        }
    }
}

struct HomeSongCard: View {
    let song: Song
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                CoverView(song: song, size: 150, radius: 10)
                    .shadow(color: .black.opacity(hover ? 0.5 : 0), radius: hover ? 14 : 0, y: hover ? 8 : 0)
                    .scaleEffect(hover ? 1.025 : 1)
                Text(song.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(song.shownArtist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

struct MixTile: View {
    let title: String
    let sub: String
    let cover: Song?
    let icon: String
    let tint: Color
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                CoverView(song: cover, size: 150, radius: 12)
                    .overlay(LinearGradient(colors: [tint.opacity(0.15), tint.opacity(0.85)], startPoint: .top, endPoint: .bottom))
                    .overlay(alignment: .topLeading) { Image(systemName: icon).font(.system(size: 15, weight: .bold)).foregroundStyle(.white).padding(10) }
                    .overlay(alignment: .bottomLeading) { Text(title).font(.system(size: 15, weight: .heavy)).foregroundStyle(.white).lineLimit(2).padding(10) }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(hover ? 0.5 : 0), radius: hover ? 14 : 0, y: hover ? 8 : 0)
                    .scaleEffect(hover ? 1.025 : 1)
                Text(sub).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

// MARK: - Replay

struct ReplayStats {
    var minutes = 0
    var plays = 0
    var songs: [(Song, Int)] = []
    var artists: [(String, Int, Song?)] = []
    var albums: [(AlbumInfo, Int)] = []
}

struct ReplayView: View {
    enum Period: String, CaseIterable, Identifiable {
        case month = "This Month", last = "Last Month", year = "This Year", all = "All Time"
        var id: String { rawValue }
    }
    @EnvironmentObject var lib: Library
    @EnvironmentObject var player: Player
    @State private var period = Period.month

    private func range(_ p: Period) -> (Double, Double)? {
        let cal = Calendar.current, now = Date()
        switch p {
        case .month:
            let s = cal.date(from: cal.dateComponents([.year, .month], from: now))!
            return (s.timeIntervalSince1970, .infinity)
        case .last:
            let this = cal.date(from: cal.dateComponents([.year, .month], from: now))!
            let prev = cal.date(byAdding: .month, value: -1, to: this)!
            return (prev.timeIntervalSince1970, this.timeIntervalSince1970)
        case .year:
            let s = cal.date(from: cal.dateComponents([.year], from: now))!
            return (s.timeIntervalSince1970, .infinity)
        case .all: return nil
        }
    }

    private func stats(_ p: Period) -> ReplayStats {
        var counts: [String: Int] = [:]
        var seconds = 0.0
        if let r = range(p) {
            for e in PlayLog.shared.entries where e.t >= r.0 && e.t < r.1 { counts[e.s, default: 0] += 1; seconds += e.d }
        } else {
            for s in lib.songs where (s.plays ?? 0) > 0 { counts[s.id] = s.plays!; seconds += s.duration * Double(s.plays!) }
        }
        var st = ReplayStats()
        st.minutes = Int(seconds / 60); st.plays = counts.values.reduce(0, +)
        let songs = counts.compactMap { (id, n) in lib.byID[id].map { ($0, n) } }.sorted { $0.1 > $1.1 }
        st.songs = Array(songs.prefix(10))
        var artists: [String: (Int, Song?)] = [:]; var albums: [String: (AlbumInfo, Int)] = [:]
        for (s, n) in songs {
            var e = artists[s.artistKey] ?? (0, nil)
            e.0 += n
            if e.1 == nil || (e.1!.cover.isEmpty && !s.cover.isEmpty) { e.1 = s }
            artists[s.artistKey] = e
            if let a = lib.albums.first(where: { $0.id == s.albumKey }) { albums[a.id, default: (a, 0)].1 += n }
        }
        st.artists = artists.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.1 > $1.1 }.prefix(5).map { $0 }
        st.albums = albums.values.sorted { $0.1 > $1.1 }.prefix(5).map { $0 }
        return st
    }

    var body: some View {
        let st = stats(period)
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack {
                    Picker("", selection: $period) { ForEach(Period.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 360)
                    Spacer()
                    if !st.songs.isEmpty {
                        Button { saveCard(st) } label: { Label("Save Image…", systemImage: "square.and.arrow.down") }
                        Button { copyCard(st) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    }
                }
                if st.songs.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "chart.bar.xaxis").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("Nothing to show for \(period.rawValue.lowercased()) yet").font(.title3.weight(.semibold))
                        Text("Listen to some music and your recap fills in here. Counting started with this update.").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.top, 60)
                } else {
                    HStack(spacing: 14) {
                        stat("\(st.minutes.formatted())", "minutes listened")
                        stat("\(st.plays.formatted())", "plays")
                        stat("\(st.artists.count == 5 ? "5+" : "\(st.artists.count)")", "top artists")
                    }
                    Text("Top songs").font(.title3.weight(.bold))
                    VStack(spacing: 0) {
                        ForEach(Array(st.songs.enumerated()), id: \.offset) { i, e in
                            HStack(spacing: 12) {
                                Text("\(i + 1)").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(.secondary).frame(width: 26)
                                CoverView(song: e.0, size: 40, radius: 6)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(e.0.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                                    Text(e.0.shownArtist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text("\(e.1) plays").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(i % 2 == 0 ? Color.white.opacity(0.04) : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { player.play(e.0, in: st.songs.map { $0.0 }) }
                        }
                    }.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Text("Top artists").font(.title3.weight(.bold))
                    HStack(alignment: .top, spacing: 22) {
                        ForEach(Array(st.artists.enumerated()), id: \.offset) { _, a in
                            NavigationLink(value: ArtistRef(name: a.0)) {
                                VStack(spacing: 6) {
                                    CoverView(song: a.2, size: 110, radius: 55)
                                    Text(a.0).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).frame(width: 110)
                                    Text("\(a.1) plays").font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                    if !st.albums.isEmpty {
                        Text("Top albums").font(.title3.weight(.bold))
                        HStack(alignment: .top, spacing: 18) { ForEach(st.albums, id: \.0.id) { AlbumCard(a: $0.0, size: 130) } }
                    }
                }
            }
            .padding(24).padding(.bottom, 90)
        }
    }

    private func stat(_ big: String, _ small: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(big).font(.system(size: 34, weight: .heavy, design: .rounded)).foregroundStyle(player.accent)
            Text(small).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).glass(16)
    }

    @MainActor private func card(_ st: ReplayStats) -> NSImage? {
        // pictures are normally loaded a moment after a view appears; a picture taken right now needs them ready
        for e in st.songs.prefix(5) { _ = Covers.image(e.0, maxPixel: 168) }
        for a in st.artists.prefix(3) { _ = Covers.image(a.2, maxPixel: 260) }
        let r = ImageRenderer(content: ReplayCard(period: period.rawValue, stats: st, accent: Covers.accent(st.songs.first?.0)).frame(width: 1080, height: 1350))
        r.scale = 1
        return r.nsImage
    }
    @MainActor private func saveCard(_ st: ReplayStats) {
        guard let img = card(st), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return }
        let p = NSSavePanel(); p.allowedContentTypes = [.png]; p.nameFieldStringValue = "Strata Replay \(period.rawValue).png"
        if p.runModal() == .OK, let u = p.url { try? png.write(to: u) }
    }
    @MainActor private func copyCard(_ st: ReplayStats) {
        guard let img = card(st) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([img])
        lib.flash("Copied the image")
    }
}

/// the picture you can share
struct ReplayCard: View {
    let period: String
    let stats: ReplayStats
    let accent: Color
    var body: some View {
        ZStack {
            LinearGradient(colors: [accent.opacity(0.95), Color(red: 0.05, green: 0.04, blue: 0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 26) {
                Text("STRATA REPLAY").font(.system(size: 30, weight: .heavy, design: .rounded)).tracking(5).foregroundStyle(.white.opacity(0.8))
                Text(period).font(.system(size: 64, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(stats.minutes.formatted()).font(.system(size: 120, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                    Text("minutes").font(.system(size: 38, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                }
                Text("TOP SONGS").font(.system(size: 24, weight: .bold)).tracking(4).foregroundStyle(.white.opacity(0.7)).padding(.top, 6)
                ForEach(Array(stats.songs.prefix(5).enumerated()), id: \.offset) { i, e in
                    HStack(spacing: 20) {
                        Text("\(i + 1)").font(.system(size: 40, weight: .heavy, design: .rounded)).foregroundStyle(.white.opacity(0.6)).frame(width: 50)
                        CoverView(song: e.0, size: 84, radius: 12)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.0.title).font(.system(size: 34, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                            Text(e.0.shownArtist).font(.system(size: 26)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                        }
                        Spacer()
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 22) {
                    ForEach(Array(stats.artists.prefix(3).enumerated()), id: \.offset) { _, a in
                        VStack(spacing: 8) {
                            CoverView(song: a.2, size: 130, radius: 65)
                            Text(a.0).font(.system(size: 24, weight: .semibold)).foregroundStyle(.white).lineLimit(1).frame(width: 190)
                        }
                    }
                    Spacer()
                }
            }
            .padding(70)
        }
    }
}

// MARK: - keyboard in the search drop-down

final class SearchNav: ObservableObject {
    @Published var sel = -1
    var actions: [() -> Void] = []
    func move(_ d: Int) { sel = max(-1, min(actions.count - 1, sel + d)) }
    @discardableResult func activate() -> Bool {
        guard actions.indices.contains(sel) else { return false }
        actions[sel](); return true
    }
}
