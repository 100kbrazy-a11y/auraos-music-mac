import SwiftUI
import AppKit

enum Nav: Hashable {
    case songs, recent, albums, artists, favorites, duplicates
    case smart(String)
    case youtube, downloads, settings
    case playlist(String)
}

struct RootView: View {
    @EnvironmentObject var lib: Library
    @EnvironmentObject var player: Player
    @EnvironmentObject var updater: Updater
    @ObservedObject var dl = Downloads.shared
    @AppStorage("leaves") private var leaves = true
    @State private var nav: Nav? = .songs
    @State private var path = NavigationPath()
    @State private var showPlayer = false
    @State private var search = ""
    @State private var dropping = false
    @FocusState private var searchFocus: Bool
    @State private var windowFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)
    @State private var escMonitor: Any?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var grab = ArtistGrab.shared

    private var showLeaves: Bool { leaves && !reduceMotion }

    var body: some View {
        ZStack {
            NavigationSplitView {
                SidebarView(nav: Binding(get: { nav }, set: { nav = $0; path = NavigationPath() }))
                    .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 280)
            } detail: {
                DetailRoot(nav: nav ?? .songs, search: search, path: $path)
                    .background { if showLeaves { DetailLeaves(window: windowFrame) } }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if player.current != nil {
                            NowPlayingBar(open: openPlayer)
                                .opacity(showPlayer ? 0 : 1).offset(y: showPlayer ? -90 : 0).scaleEffect(showPlayer ? 0.96 : 1, anchor: .top)
                                .allowsHitTesting(!showPlayer)
                        }
                    }
                    .overlay(alignment: .top) {
                        if !lib.status.isEmpty {
                            Text(lib.status).font(.system(size: 12, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 7).glass(16).padding(.top, 8)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
            }
            // the sidebar button, the title and the search box belong to the library, not to the full-screen player
            .toolbar(showPlayer ? .hidden : .automatic, for: .windowToolbar)
            .toolbar {
                ToolbarItem(placement: .automatic) { SearchField(text: $search, focus: $searchFocus) }
                ToolbarItem(placement: .automatic) { Button { lib.pickMusic() } label: { Label("Add Music", systemImage: "plus") }.help("Add a music folder or songs") }
            }
            .animation(.easeInOut(duration: 0.2), value: lib.status)

            // typing in the search box: the page dims and a list of matches drops down
            if searchFocus && !showPlayer {
                Color.black.opacity(0.5).ignoresSafeArea()
                    .onTapGesture { searchFocus = false }
                    .transition(.opacity).zIndex(1)
                HStack { Spacer(); SearchDropdown(query: search, openSong: openSong, openAlbum: openAlbum, openArtist: openArtist, web: searchWeb).padding(.top, 6).padding(.trailing, 14) }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .top).combined(with: .opacity)).zIndex(2)
            }

            // the player's backdrop only fades in (it never slides), and its leaves sit exactly where the library's leaves are,
            // so opening the player doesn't restart or speed them up
            if showPlayer {
                ZStack {
                    AuroraBackground(color: player.accent)
                    if showLeaves { FallingLeaves(area: windowFrame.size) }
                }
                .ignoresSafeArea().transition(.opacity).zIndex(3)
            }
            if showPlayer {
                FullPlayerView(close: closePlayer)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(5)
            }
        }
        .animation(.easeOut(duration: 0.18), value: searchFocus)
        .dropDestination(for: URL.self) { urls, _ in lib.importURLs(urls, remember: true); return true } isTargeted: { dropping = $0 }
        .overlay { if dropping { RoundedRectangle(cornerRadius: 14).strokeBorder(player.accent, lineWidth: 3).padding(6).allowsHitTesting(false) } }
        .background(Color(red: 0.07, green: 0.07, blue: 0.08))
        .background(GeometryReader { g in
            Color.clear
                .onAppear { windowFrame = g.frame(in: .global) }
                .onChange(of: g.size) { _ in windowFrame = g.frame(in: .global) }
        }.ignoresSafeArea())
        .background(WindowAccessor { w in
            _ = w.setFrameAutosaveName("StrataMainWindow")
            w.titleVisibility = showPlayer ? .hidden : .visible
            w.titlebarAppearsTransparent = showPlayer
        })
        .overlay { UpdatePrompt() }
        .overlay { ArtistGrabPrompt() }
        .onAppear { Downloads.shared.lib = lib; player.restoreLast(lib) }
        .onChange(of: showPlayer) { on in
            if on {
                // Esc closes the player (unless a menu, popover or sheet is open and wants the key first)
                escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
                    guard ev.keyCode == 53, let kw = NSApp.keyWindow, kw.attachedSheet == nil, !kw.className.contains("Popover"), !(kw is NSPanel) else { return ev }
                    closePlayer(); return nil
                }
            } else if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ytSearch)) { n in
            if let a = n.object as? [String], a.count == 2 {
                YouTube.shared.query = a[0]; YouTube.shared.type = a[1]; nav = .youtube; path = NavigationPath()
                Task { await YouTube.shared.run() }
            }
            if showPlayer { closePlayer() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPlayer)) { _ in openPlayer() }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in if !showPlayer { searchFocus = true } }
        .onReceive(NotificationCenter.default.publisher(for: .showDownloads)) { _ in nav = .downloads; path = NavigationPath() }
        .onReceive(NotificationCenter.default.publisher(for: .goRef)) { n in
            if let a = n.object as? AlbumRef { openAlbum(a.key) } else if let a = n.object as? ArtistRef { openArtist(a.name) }
            if showPlayer { closePlayer() }
        }
    }

    private func openPlayer() { searchFocus = false; withAnimation(.spring(response: 0.46, dampingFraction: 0.9)) { showPlayer = true } }
    private func closePlayer() { withAnimation(.spring(response: 0.42, dampingFraction: 0.92)) { showPlayer = false } }

    private func finishSearch() { search = ""; searchFocus = false }
    private func openSong(_ s: Song, _ list: [Song]) { player.play(s, in: list); finishSearch() }
    private func openAlbum(_ key: String) { nav = .albums; path = NavigationPath(); path.append(AlbumRef(key: key)); finishSearch() }
    private func openArtist(_ name: String) { nav = .artists; path = NavigationPath(); path.append(ArtistRef(name: name)); finishSearch() }
    private func searchWeb() {
        let q = search.trimmingCharacters(in: .whitespaces)
        YouTube.shared.query = q; YouTube.shared.type = "song"
        nav = .youtube; path = NavigationPath(); search = ""; searchFocus = false
        Task { await YouTube.shared.run() }
    }
}

extension Notification.Name {
    static let openPlayer = Notification.Name("strata.openPlayer")
    static let focusSearch = Notification.Name("strata.focusSearch")
    static let goRef = Notification.Name("strata.goRef")
    static let showDownloads = Notification.Name("strata.showDownloads")
    static let ytSearch = Notification.Name("strata.ytSearch")
}

// MARK: - the search box and its drop-down

struct SearchField: View {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain).font(.system(size: 13)).focused(focus)
                .onExitCommand { text = ""; focus.wrappedValue = false }
                .onSubmit { focus.wrappedValue = false }
            if !text.isEmpty { Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .frame(width: focus.wrappedValue ? 320 : 240)
        .animation(.easeOut(duration: 0.18), value: focus.wrappedValue)
        // macOS 26's toolbar already draws its own glass pill around this; older versions get ours
        .background { if #available(macOS 26.0, *) { EmptyView() } else { Capsule().fill(Color.white.opacity(focus.wrappedValue ? 0.14 : 0.08)) } }
    }
}

struct SearchDropdown: View {
    let query: String
    var openSong: (Song, [Song]) -> Void
    var openAlbum: (String) -> Void
    var openArtist: (String) -> Void
    var web: () -> Void
    @EnvironmentObject var lib: Library
    @EnvironmentObject var player: Player

    private var q: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        let songs = q.isEmpty ? [] : lib.songs.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.artist.localizedCaseInsensitiveContains(q) || $0.album.localizedCaseInsensitiveContains(q) }
        let albums = q.isEmpty ? [] : lib.albums.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.artist.localizedCaseInsensitiveContains(q) }
        let artists = q.isEmpty ? [] : lib.artists.filter { $0.id.localizedCaseInsensitiveContains(q) }
        VStack(alignment: .leading, spacing: 0) {
            if !q.isEmpty {
                Button(action: web) {
                    HStack(spacing: 10) {
                        Image(systemName: "globe").font(.system(size: 15, weight: .semibold)).frame(width: 30, height: 30).background(Circle().fill(player.accent.opacity(0.35)))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Not showing up? Search the web →").font(.system(size: 13, weight: .semibold))
                            Text("Look for “\(q)” on YouTube and download it").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().opacity(0.5)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if q.isEmpty {
                        Text("Search your songs, albums and artists").foregroundStyle(.secondary).font(.system(size: 12.5)).padding(16)
                    } else if songs.isEmpty && albums.isEmpty && artists.isEmpty {
                        Text("Nothing in your library matches “\(q)”").foregroundStyle(.secondary).font(.system(size: 12.5)).padding(16)
                    }
                    if !songs.isEmpty {
                        header("Songs")
                        ForEach(songs.prefix(6)) { s in
                            row(CoverView(song: s, size: 34, radius: 6), s.title, s.shownArtist + (s.album.isEmpty ? "" : " · " + s.album), s.id == player.current?.id) { openSong(s, songs) }
                        }
                    }
                    if !albums.isEmpty {
                        header("Albums")
                        ForEach(albums.prefix(3)) { a in row(CoverView(song: a.cover, size: 34, radius: 6), a.title, a.artist, false) { openAlbum(a.id) } }
                    }
                    if !artists.isEmpty {
                        header("Artists")
                        ForEach(artists.prefix(3)) { a in row(CoverView(song: a.cover, size: 34, radius: 17), a.id, "\(a.songs.count) songs", false) { openArtist(a.id) } }
                    }
                }
                .padding(.bottom, 6)
            }
            .frame(maxHeight: 380)
        }
        .frame(width: 400)
        .glass(18)
        .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
    }

    private func header(_ t: String) -> some View {
        Text(t).font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary).textCase(.uppercase).padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 2)
    }

    private func row<C: View>(_ cover: C, _ title: String, _ sub: String, _ playing: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                cover
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1).foregroundStyle(playing ? player.accent : Color.primary)
                    Text(sub).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - sidebar

struct SidebarView: View {
    @Binding var nav: Nav?
    @EnvironmentObject var lib: Library
    @EnvironmentObject var updater: Updater
    @ObservedObject var dl = Downloads.shared
    @State private var renaming: Playlist?
    @State private var newName = ""
    @State private var editingSmart: SmartPlaylist?

    var body: some View {
        List(selection: $nav) {
            Section("Library") {
                Label("Songs", systemImage: "music.note").tag(Nav.songs)
                Label("Recently Added", systemImage: "clock").tag(Nav.recent)
                Label("Albums", systemImage: "square.stack").tag(Nav.albums)
                Label("Artists", systemImage: "music.mic").tag(Nav.artists)
                Label("Favorites", systemImage: "heart").tag(Nav.favorites)
                Label("Duplicates", systemImage: "square.on.square").tag(Nav.duplicates)
            }
            Section("Smart Playlists") {
                ForEach(SmartPlaylist.builtIn + lib.smart) { sp in
                    Label(sp.name, systemImage: "gearshape.2").tag(Nav.smart(sp.id))
                        .contextMenu {
                            if !sp.isBuiltIn {
                                Button("Edit…") { editingSmart = sp }
                                Button("Delete", role: .destructive) { if nav == .smart(sp.id) { nav = .songs }; lib.deleteSmart(sp.id) }
                            }
                        }
                }
                Button { editingSmart = SmartPlaylist() } label: { Label("New Smart Playlist", systemImage: "plus") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Section("YouTube") {
                Label("Search & Download", systemImage: "magnifyingglass").tag(Nav.youtube)
                Label("Downloads", systemImage: "arrow.down.circle").badge(dl.active).tag(Nav.downloads)
            }
            Section("Playlists") {
                ForEach(lib.playlists) { p in
                    Label(p.name, systemImage: "music.note.list").tag(Nav.playlist(p.id))
                        .contextMenu {
                            Button("Rename…") { newName = p.name; renaming = p }
                            Button("Duplicate") { lib.duplicate(p) }
                            Button("Export as M3U…") { lib.exportM3U(p) }
                            Button("Delete", role: .destructive) { if nav == .playlist(p.id) { nav = .songs }; lib.deletePlaylist(p.id) }
                        }
                }
                Button { lib.newPlaylist("New Playlist") } label: { Label("New Playlist", systemImage: "plus") }.buttonStyle(.plain).foregroundStyle(.secondary)
                Button { lib.importM3U() } label: { Label("Import Playlist…", systemImage: "square.and.arrow.down") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if let r = updater.available {
                    Button { updater.showPrompt = true } label: {
                        Label("Update to \(r.version)", systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button { nav = .settings } label: { Label("Settings", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading) }
                    .buttonStyle(.plain).foregroundStyle(nav == .settings ? Color.primary : Color.secondary)
            }
            .padding(10)
        }
        .sheet(item: $editingSmart) { sp in SmartEditor(sp: sp, isNew: !lib.smart.contains { $0.id == sp.id }) }
        .alert("Rename Playlist", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let p = renaming { lib.rename(p.id, to: newName) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }
}

// MARK: - the page next to the sidebar

struct DetailRoot: View {
    let nav: Nav
    let search: String
    @Binding var path: NavigationPath
    @EnvironmentObject var lib: Library

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch nav {
                case .songs: SongTable(songs: lib.songs, search: search)
                case .recent: SongTable(songs: lib.recentSongs, search: search, recent: true)
                case .albums: AlbumsView(search: search)
                case .artists: ArtistsView(search: search)
                case .favorites: SongTable(songs: lib.favoriteSongs, search: search)
                case .duplicates: DuplicatesView()
                case .smart(let id):
                    if let sp = lib.smartPlaylist(id) { SongTable(songs: lib.songs(in: sp), search: search, keepOrder: true) } else { Text("This playlist is gone.").foregroundStyle(.secondary) }
                case .youtube: YouTubeView()
                case .downloads: DownloadsView()
                case .settings: SettingsView(embedded: true)
                case .playlist(let id):
                    if let p = lib.playlists.first(where: { $0.id == id }) { SongTable(songs: lib.songs(in: p), search: search) } else { Text("This playlist is gone.").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(title)
            .navigationDestination(for: AlbumRef.self) { AlbumDetail(key: $0.key) }
            .navigationDestination(for: ArtistRef.self) { ArtistDetail(name: $0.name) }
            .navigationDestination(for: YtCollection.self) { YtCollectionView(c: $0) }
            .navigationDestination(for: YtArtistRef.self) { YtArtistView(a: $0) }
        }
        .id(nav)
    }

    private var title: String {
        switch nav {
        case .songs: return "Songs"
        case .recent: return "Recently Added"
        case .albums: return "Albums"
        case .artists: return "Artists"
        case .favorites: return "Favorites"
        case .duplicates: return "Duplicates"
        case .smart(let id): return lib.smartPlaylist(id)?.name ?? "Smart Playlist"
        case .youtube: return "Search & Download"
        case .downloads: return "Downloads"
        case .settings: return "Settings"
        case .playlist(let id): return lib.playlists.first(where: { $0.id == id })?.name ?? "Playlist"
        }
    }
}

// MARK: - the media bar (a glass capsule floating over the page)

struct TransportButtons: View {
    @EnvironmentObject var player: Player
    var big = false
    var body: some View {
        HStack(spacing: big ? 30 : 16) {
            Button { player.previous() } label: { Image(systemName: "backward.fill").font(.system(size: big ? 26 : 15)) }
            Button { player.togglePlay() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: big ? 42 : 20)).frame(width: big ? 56 : 26) }
            Button { player.next() } label: { Image(systemName: "forward.fill").font(.system(size: big ? 26 : 15)) }
        }
        .buttonStyle(.plain)
    }
}

struct SeekBar: View {
    @ObservedObject var clock: Clock
    var duration: Double
    var onSeek: (Double) -> Void
    @State private var dragging: Double?

    var body: some View {
        GeometryReader { g in
            let shown = dragging ?? clock.position
            let frac = duration > 0 ? min(1, max(0, shown / duration)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22)).frame(height: 5)
                Capsule().fill(Color.white).frame(width: max(5, g.size.width * CGFloat(frac)), height: 5)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in dragging = Double(min(1, max(0, v.location.x / max(1, g.size.width)))) * duration }
                .onEnded { v in onSeek(Double(min(1, max(0, v.location.x / max(1, g.size.width)))) * duration); dragging = nil })
        }
        .frame(height: 18)
    }
}

struct TimeLabels: View {
    @ObservedObject var clock: Clock
    var duration: Double
    var body: some View {
        HStack {
            Text(fmtTime(clock.position))
            Spacer()
            Text("-" + fmtTime(max(0, duration - clock.position)))
        }
        .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.6))
    }
}

struct NowPlayingBar: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var lib: Library
    var open: () -> Void

    var body: some View {
        if let s = player.current {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    CoverView(song: s, size: 46, radius: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Text(s.shownArtist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            .onTapGesture { NotificationCenter.default.post(name: .goRef, object: ArtistRef(name: s.artistKey)) }
                    }
                    Spacer(minLength: 12)
                    Button { lib.toggleFav(s) } label: { Image(systemName: lib.isFav(s) ? "heart.fill" : "heart").foregroundStyle(lib.isFav(s) ? player.accent : Color.secondary) }
                        .buttonStyle(.plain).help("Favorite")
                    TransportButtons()
                    QueueButton().foregroundStyle(.secondary).padding(.leading, 4)
                    Button { open() } label: { Image(systemName: "chevron.up").font(.system(size: 13, weight: .bold)) }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.leading, 6)
                }
                .padding(.horizontal, 14).padding(.top, 9).padding(.bottom, 4)
                SeekBar(clock: player.clock, duration: s.duration) { player.seek(to: $0) }.padding(.horizontal, 16).padding(.bottom, 4)
            }
            .frame(maxWidth: 720)
            .glass(26, tint: player.accent)
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .onTapGesture(perform: open)
            .padding(.horizontal, 18).padding(.bottom, 14)
            .frame(maxWidth: .infinity)
        }
    }
}
