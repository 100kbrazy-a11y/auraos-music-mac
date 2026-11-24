import SwiftUI
import AppKit

struct AlbumRef: Hashable { var key: String }
struct ArtistRef: Hashable { var name: String }

// MARK: - songs (Apple Music's table)

struct SongTable: View {
    let songs: [Song]
    var search: String = ""
    @EnvironmentObject var lib: Library
    @EnvironmentObject var player: Player
    @State private var selection = Set<String>()
    @State private var order: [KeyPathComparator<Song>]
    @State private var exporting: Song?
    @State private var editing: Song?
    @AppStorage("listCover") private var listCover = 34.0

    init(songs: [Song], search: String = "", recent: Bool = false, keepOrder: Bool = false) {
        self.songs = songs; self.search = search
        _order = State(initialValue: keepOrder ? [] : recent ? [KeyPathComparator(\Song.added, order: .reverse)] : [KeyPathComparator(\Song.title)])
    }

    /// sorting thousands of titles with the system's string rules takes a while, so it's done away from the main thread, and only when something it depends on changed
    @State private var sortedList: [Song] = []

    private struct SortKey: Equatable { var sig: Int; var search: String; var order: String }
    private var sortKey: SortKey {
        var h = Hasher()
        h.combine(songs.count)
        for s in songs { h.combine(s.id); h.combine(s.title); h.combine(s.artist); h.combine(s.album); h.combine(s.plays); h.combine(s.duration); h.combine(s.added) }
        return SortKey(sig: h.finalize(), search: search, order: order.map { "\(String(describing: $0.keyPath))\($0.order)" }.joined(separator: ","))
    }

    private static func filtered(_ songs: [Song], _ search: String) -> [Song] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? songs : songs.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.artist.localizedCaseInsensitiveContains(q) || $0.album.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        let list = sortedList.isEmpty ? Self.filtered(songs, search) : sortedList
        Table(list, selection: $selection, sortOrder: $order) {
            TableColumn("Title", value: \.title) { s in
                HStack(spacing: 10) {
                    CoverView(song: s, size: CGFloat(listCover), radius: 6)
                    Text(s.title).lineLimit(1).foregroundStyle(player.current?.id == s.id ? player.accent : Color.primary)
                    if player.current?.id == s.id { EqBars(playing: player.isPlaying, color: player.accent) }
                    if lib.isFav(s) { Image(systemName: "heart.fill").font(.system(size: 9)).foregroundStyle(player.accent) }
                }
            }
            TableColumn("Artist", value: \.artist) { s in Text(s.shownArtist).lineLimit(1).foregroundStyle(.secondary) }
            TableColumn("Album", value: \.album) { s in Text(s.shownAlbum).lineLimit(1).foregroundStyle(.secondary) }
            TableColumn("Plays") { s in Text((s.plays ?? 0) > 0 ? "\(s.plays!)" : "").monospacedDigit().foregroundStyle(.secondary) }.width(44)
            TableColumn("Time", value: \.duration) { s in Text(fmtTime(s.duration)).monospacedDigit().foregroundStyle(.secondary) }.width(56)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let picked = ids.compactMap { lib.byID[$0] }
            if let first = picked.first {
                Button("Play") { player.play(first, in: list) }
                Button("Play Next") { for s in picked.reversed() { player.playNext(s) } }
                Button("Add to Queue") { for s in picked { player.enqueue(s) } }
                Button("Start Radio") { Radio.shared.start(from: first) }
                Divider()
                Button(lib.isFav(first) ? "Remove from Favorites" : "Add to Favorites") { let was = lib.isFav(first); for s in picked where lib.isFav(s) == was { lib.toggleFav(s) } }
                Menu("Add to Playlist") {
                    ForEach(lib.playlists) { p in Button(p.name) { lib.add(picked.map { $0.id }, to: p.id) } }
                    Divider()
                    Button("New Playlist…") { lib.newPlaylist("New Playlist", with: picked.map { $0.id }) }
                }
                Divider()
                Button("Go to Album") { NotificationCenter.default.post(name: .goRef, object: AlbumRef(key: first.albumKey)) }
                Button("Go to Artist") { NotificationCenter.default.post(name: .goRef, object: ArtistRef(name: first.artistKey)) }
                Divider()
                Button("Edit Info…") { editing = first }
                Button("Export…") { exporting = first }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(picked.map { $0.url }) }
                Button("Remove from Library", role: .destructive) { lib.remove(Set(ids)) }
            }
        } primaryAction: { ids in
            if let id = ids.first, let s = lib.byID[id] { player.play(s, in: list) }
        }
        .scrollContentBackground(.hidden)
        .task(id: sortKey) {
            let snapshot = songs, q = search, ord = order
            let result = await Task.detached(priority: .userInitiated) { Self.filtered(snapshot, q).sorted(using: ord) }.value
            if !Task.isCancelled { sortedList = result }
        }
        .sheet(item: $exporting) { ExportSheet(song: $0) }
        .sheet(item: $editing) { EditInfoSheet(song: $0) }
        .overlay { if songs.isEmpty { EmptyLibrary() } }
    }
}

struct EmptyLibrary: View {
    @EnvironmentObject var lib: Library
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.house").font(.system(size: 54)).foregroundStyle(.secondary)
            Text("Nothing here yet").font(.title2.weight(.semibold))
            Text("Add a folder of music, or drop songs and folders on this window.").foregroundStyle(.secondary)
            Button("Add Music…") { lib.pickMusic() }.buttonStyle(.borderedProminent).controlSize(.large)
        }
    }
}

// MARK: - albums

struct AlbumGrid: View {
    let albums: [AlbumInfo]
    var size: CGFloat = 168
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: size, maximum: size + 40), spacing: 22, alignment: .top)], alignment: .leading, spacing: 26) {
            ForEach(albums) { a in AlbumCard(a: a, size: size) }
        }
    }
}

/// an album's cover and name; hover it for a play button, like Apple Music
struct AlbumCard: View {
    let a: AlbumInfo
    let size: CGFloat
    @EnvironmentObject var player: Player
    @State private var hover = false
    var body: some View {
        ZStack(alignment: .topLeading) {
            NavigationLink(value: AlbumRef(key: a.id)) {
                VStack(alignment: .leading, spacing: 6) {
                    CoverView(song: a.cover, size: size, radius: 10)
                        .shadow(color: .black.opacity(hover ? 0.5 : 0.3), radius: hover ? 14 : 8, y: hover ? 8 : 4)
                        .scaleEffect(hover ? 1.025 : 1)
                    Text(a.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(a.artist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(width: size, alignment: .leading)
            }
            .buttonStyle(.plain)
            if hover, let f = a.songs.first {
                Button { player.play(f, in: a.songs) } label: {
                    Image(systemName: "play.fill").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 38, height: 38).background(Circle().fill(.black.opacity(0.55))).overlay(Circle().strokeBorder(.white.opacity(0.25)))
                }
                .buttonStyle(.plain).padding(10).offset(y: size - 58 + 0).transition(.scale.combined(with: .opacity))
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

struct AlbumsView: View {
    @EnvironmentObject var lib: Library
    var search: String
    var body: some View {
        let q = search.trimmingCharacters(in: .whitespaces)
        let list = q.isEmpty ? lib.albums : lib.albums.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.artist.localizedCaseInsensitiveContains(q) }
        ScrollView { AlbumGrid(albums: list).padding(24).padding(.bottom, 80) }
            .overlay { if lib.songs.isEmpty { EmptyLibrary() } }
    }
}

struct SongRows: View {
    let songs: [Song]
    var showCover = false
    @AppStorage("listCover") private var listCover = 34.0
    @EnvironmentObject var lib: Library
    @EnvironmentObject var player: Player
    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(songs.enumerated()), id: \.element.id) { i, s in
                HStack(spacing: 12) {
                    if showCover { CoverView(song: s, size: CGFloat(listCover) + 2, radius: 6) }
                    else { Text(s.track > 0 ? "\(s.track)" : "\(i + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 28, alignment: .trailing) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.title).lineLimit(1).foregroundStyle(player.current?.id == s.id ? player.accent : Color.primary)
                        if showCover || !s.artist.isEmpty { Text(s.shownArtist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer()
                    if lib.isFav(s) { Image(systemName: "heart.fill").font(.system(size: 10)).foregroundStyle(player.accent) }
                    Text(fmtTime(s.duration)).monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(i % 2 == 0 ? Color.white.opacity(0.03) : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { player.play(s, in: songs) }
                .contextMenu {
                    Button("Play") { player.play(s, in: songs) }
                    Button("Play Next") { player.playNext(s) }
                    Button("Add to Queue") { player.enqueue(s) }
                    Button(lib.isFav(s) ? "Remove from Favorites" : "Add to Favorites") { lib.toggleFav(s) }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct PlayButtons: View {
    let songs: [Song]
    @EnvironmentObject var player: Player
    var body: some View {
        HStack(spacing: 10) {
            Button { player.playAll(songs, shuffled: false) } label: { Label("Play", systemImage: "play.fill").frame(minWidth: 70) }.buttonStyle(.borderedProminent).tint(player.accent)
            Button { player.playAll(songs, shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle").frame(minWidth: 70) }.buttonStyle(.bordered)
        }
        .controlSize(.large)
    }
}

struct AlbumDetail: View {
    let key: String
    @EnvironmentObject var lib: Library
    var body: some View {
        if let a = lib.albums.first(where: { $0.id == key }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .bottom, spacing: 24) {
                        CoverView(song: a.cover, size: 220, radius: 14).shadow(color: .black.opacity(0.4), radius: 20, y: 10)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(a.title).font(.system(size: 28, weight: .bold)).lineLimit(2)
                            NavigationLink(value: ArtistRef(name: a.artist)) { Text(a.artist).font(.system(size: 18)).foregroundStyle(.secondary) }.buttonStyle(.plain)
                            Text([a.year, "\(a.songs.count) songs", fmtTime(a.songs.reduce(0) { $0 + $1.duration })].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(.secondary)
                            HStack(spacing: 10) {
                                PlayButtons(songs: a.songs)
                                Button { Radio.shared.start(album: a) } label: { Label("Radio", systemImage: "dot.radiowaves.left.and.right") }.buttonStyle(.bordered).controlSize(.large)
                            }.padding(.top, 6)
                        }
                        Spacer()
                    }
                    SongRows(songs: a.songs)
                }
                .padding(24).padding(.bottom, 80)
            }
            .navigationTitle(a.title)
        } else { Text("This album is gone.").foregroundStyle(.secondary) }
    }
}

// MARK: - artists

struct ArtistsView: View {
    @EnvironmentObject var lib: Library
    var search: String
    var body: some View {
        let q = search.trimmingCharacters(in: .whitespaces)
        let list = q.isEmpty ? lib.artists : lib.artists.filter { $0.id.localizedCaseInsensitiveContains(q) }
        List(list) { a in
            NavigationLink(value: ArtistRef(name: a.id)) {
                HStack(spacing: 14) {
                    CoverView(song: a.cover, size: 46, radius: 23)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.id).font(.system(size: 14, weight: .semibold))
                        Text("\(a.albums.count) albums · \(a.songs.count) songs").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 3)
            }
        }
        .scrollContentBackground(.hidden)
        .overlay { if lib.songs.isEmpty { EmptyLibrary() } }
    }
}

struct ArtistDetail: View {
    let name: String
    @EnvironmentObject var lib: Library
    @EnvironmentObject var player: Player
    @ObservedObject var profiles = ArtistProfiles.shared
    @State private var moreBio = false

    var body: some View {
        if let a = lib.artists.first(where: { $0.id == name }) {
            let profile = profiles.cache[name]
            let top = a.songs.filter { ($0.plays ?? 0) > 0 }.sorted { ($0.plays ?? 0) > ($1.plays ?? 0) }.prefix(5)
            let albums = a.albums.filter { $0.songs.count > 2 }
            let singles = a.albums.filter { $0.songs.count <= 2 }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header(a, profile)
                    if let bio = profile?.bio, !bio.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(bio).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(moreBio ? nil : 3)
                            HStack(spacing: 12) {
                                Button(moreBio ? "Less" : "More") { withAnimation { moreBio.toggle() } }.buttonStyle(.plain).foregroundStyle(player.accent)
                                Text("From Wikipedia").font(.system(size: 11)).foregroundStyle(.tertiary)
                            }
                        }.frame(maxWidth: 720, alignment: .leading)
                    }
                    if !top.isEmpty {
                        Text("Your top songs").font(.title3.weight(.bold))
                        SongRows(songs: Array(top), showCover: true)
                    }
                    if !albums.isEmpty { Text("Albums").font(.title3.weight(.bold)); AlbumGrid(albums: albums, size: 150) }
                    if !singles.isEmpty { Text("Singles & EPs").font(.title3.weight(.bold)); AlbumGrid(albums: singles, size: 150) }
                    Text("All songs").font(.title3.weight(.bold))
                    SongRows(songs: a.songs.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }, showCover: true)
                }
                .padding(.horizontal, 24).padding(.bottom, 90).padding(.top, 12)
            }
            .navigationTitle(a.id)
            .task { await profiles.load(name) }
        } else { Text("No songs by this artist.").foregroundStyle(.secondary) }
    }

    private func header(_ a: ArtistInfo, _ profile: ArtistProfiles.Profile?) -> some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let p = profile?.photo, !p.isEmpty, let u = URL(string: p) {
                    AsyncImage(url: u) { ph in
                        if let img = ph.image { img.resizable().aspectRatio(contentMode: .fill) } else { fallbackBanner(a) }
                    }
                } else { fallbackBanner(a) }
            }
            .frame(maxWidth: .infinity).frame(height: 280).clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 10) {
                Text(a.id).font(.system(size: 40, weight: .heavy)).foregroundStyle(.white).shadow(radius: 6)
                if let b = profile?.blurb, !b.isEmpty { Text(b.prefix(1).uppercased() + b.dropFirst()).font(.system(size: 13)).foregroundStyle(.white.opacity(0.8)) }
                HStack(spacing: 10) {
                    PlayButtons(songs: a.songs)
                    Button { Radio.shared.start(artist: a.id) } label: { Label("Radio", systemImage: "dot.radiowaves.left.and.right").frame(minWidth: 60) }.buttonStyle(.bordered).controlSize(.large)
                    Button { NotificationCenter.default.post(name: .ytSearch, object: [a.id, "artist"]) } label: { Label("Get more", systemImage: "arrow.down.circle") }.buttonStyle(.bordered).controlSize(.large)
                }
            }
            .padding(22)
        }
        .frame(height: 280)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
    }

    private func fallbackBanner(_ a: ArtistInfo) -> some View {
        ZStack {
            if let img = Covers.image(a.cover, maxPixel: 600) { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).blur(radius: 40).scaleEffect(1.3) }
            Color.black.opacity(0.25)
        }
        .background(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.1)], startPoint: .top, endPoint: .bottom))
    }
}
