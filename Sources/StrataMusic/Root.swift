import SwiftUI
import AppKit

enum Nav: Hashable {
    case home, replay
    case songs, recent, albums, artists, favorites, duplicates
    case smart(String)
    case youtube, downloads
    case playlist(String)
}

struct RootView: View {
    @EnvironmentObject var lib: Library
    @EnvironmentObject var player: Player
    @EnvironmentObject var updater: Updater
    @AppStorage("leaves") private var leaves = true
    @AppStorage("season") private var seasonRaw = ""
    @State private var nav: Nav? = .home
    @State private var sidebarShown = true
    @State private var path = AppPath()
    @State private var showPlayer = false
    @State private var search = ""
    @State private var dropping = false
    @FocusState private var searchFocus: Bool
    @State private var windowFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)
    @State private var escMonitor: Any?
    @State private var searchMonitor: Any?
    @StateObject private var searchNav = SearchNav()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("effects") private var effects = "full"

    private var layoutPages: Bool {
        switch nav ?? .songs { case .songs, .recent, .favorites, .smart, .playlist: return true; default: return false }
    }

    private var pageTitle: String {
        switch nav ?? .songs {
        case .home: return "Home"
        case .replay: return "Replay"
        case .songs: return "Songs"
        case .recent: return "Recently Added"
        case .albums: return "Albums"
        case .artists: return "Artists"
        case .favorites: return "Favorites"
        case .duplicates: return "Duplicates"
        case .smart(let id): return lib.smartPlaylist(id)?.name ?? "Smart Playlist"
        case .youtube: return "Search & Download"
        case .downloads: return "Downloads"
        case .playlist(let id): return lib.playlists.first(where: { $0.id == id })?.name ?? "Playlist"
        }
    }

    /// the falling effect to draw (nil = none)
    private var fx: Season? { reduceMotion || effects == "light" || ProcessInfo.processInfo.isLowPowerModeEnabled ? nil : Season.resolve(seasonRaw, legacyLeaves: leaves) }

    var body: some View {
        ZStack {
            shell
            .animation(.easeInOut(duration: 0.2), value: lib.status)

            // typing in the search box: the page dims and a list of matches drops down
            if searchFocus && !showPlayer {
                Color.black.opacity(0.5).ignoresSafeArea()
                    .onTapGesture { searchFocus = false }
                    .transition(.opacity).zIndex(1)
                HStack { Spacer(); SearchDropdown(query: search, nav: searchNav, openSong: openSong, openAlbum: openAlbum, openArtist: openArtist, web: searchWeb, finish: finishSearch).padding(.top, 6).padding(.trailing, 14) }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .top).combined(with: .opacity)).zIndex(2)
            }

            // the player's backdrop only fades in (it never slides), and its leaves sit exactly where the library's leaves are,
            // so opening the player doesn't restart or speed them up
            if showPlayer {
                ZStack {
                    PlayerBackdrop(accent: player.accent, song: player.current)
                    if let fx = fx { SeasonEffect(kind: fx, area: windowFrame.size) }
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
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            // songs dragged out of this app and back in are not new files, so they're left alone
            let outside = providers.filter { !SongDrag.isOurs($0) }
            guard !outside.isEmpty else { return false }
            for p in outside {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url = url else { return }
                    Task { @MainActor in lib.importURLs([url], remember: true) }
                }
            }
            return true
        }
        .overlay { if dropping { RoundedRectangle(cornerRadius: 14).strokeBorder(player.accent, lineWidth: 3).padding(6).allowsHitTesting(false) } }
        .background(Color(red: 0.07, green: 0.07, blue: 0.08))
        .background(GeometryReader { g in
            Color.clear
                .onAppear { windowFrame = g.frame(in: .global) }
                .onChange(of: g.size) { _ in windowFrame = g.frame(in: .global) }
        }.ignoresSafeArea())
        .background(WindowAccessor { w in
            // this runs after every update of the page, so it only touches the window when something is different
            if w.frameAutosaveName != "StrataMainWindow" { _ = w.setFrameAutosaveName("StrataMainWindow") }
            let vis: NSWindow.TitleVisibility = showPlayer ? .hidden : .visible
            if w.titleVisibility != vis { w.titleVisibility = vis }
            // no separate top bar: the window's own background runs all the way up
            if !w.titlebarAppearsTransparent { w.titlebarAppearsTransparent = true }
            if w.titlebarSeparatorStyle != .none { w.titlebarSeparatorStyle = .none }
            if !w.styleMask.contains(.fullSizeContentView) { w.styleMask.insert(.fullSizeContentView) }
        })
        .overlay { UpdatePrompt() }
        .overlay { ArtistGrabPrompt() }
        .onAppear { Downloads.shared.lib = lib; player.restoreLast(lib); Sync.shared.start() }
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
                YouTube.shared.query = a[0]; YouTube.shared.type = a[1]; nav = .youtube; path.reset()
                Task { await YouTube.shared.run() }
            }
            if showPlayer { closePlayer() }
        }
        .onChange(of: search) { _ in searchNav.sel = -1 }
        .onChange(of: searchFocus) { on in
            if on {
                // arrow keys walk the list, Return opens the highlighted row, or the full YouTube results page
                searchMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
                    switch ev.keyCode {
                    case 125: searchNav.move(1); return nil
                    case 126: searchNav.move(-1); return nil
                    case 36, 76:
                        if searchNav.activate() { return nil }
                        if !search.trimmingCharacters(in: .whitespaces).isEmpty { searchWeb(); return nil }
                        return ev
                    default: return ev
                    }
                }
            } else {
                if let m = searchMonitor { NSEvent.removeMonitor(m); searchMonitor = nil }
                searchNav.sel = -1
            }
        }
        .onChange(of: showPlayer) { Presence.playerOpen = $0 }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { n in
            // the green button goes straight to the player
            if (n.object as? NSWindow)?.frameAutosaveName == "StrataMainWindow", player.current != nil, !showPlayer { openPlayer() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .jumpCurrent)) { _ in
            if let s = player.current { openAlbum(s.albumKey) }
            if showPlayer { closePlayer() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPlayer)) { _ in openPlayer() }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in if !showPlayer { searchFocus = true } }
        .onReceive(NotificationCenter.default.publisher(for: .showDownloads)) { _ in nav = .downloads; path.reset() }
        .onReceive(NotificationCenter.default.publisher(for: .goRef)) { n in
            if let a = n.object as? AlbumRef { openAlbum(a.key) } else if let a = n.object as? ArtistRef { openArtist(a.name) }
            if showPlayer { closePlayer() }
        }
    }

    private var sidebar: some View {
        SidebarView(nav: Binding(get: { nav }, set: { nav = $0; path.reset() }))
    }

    /// the page next to the sidebar, with its top edge and the player bar under it
    private var detailPage: some View {
        DetailRoot(nav: nav ?? .songs, search: search, path: $path)
                    .background { if let fx = fx { DetailEffect(window: windowFrame, kind: fx) } }
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if !showPlayer {
                            TopHeader(title: pageTitle, canGoBack: !path.isEmpty, back: { if !path.isEmpty { path.removeLast() } },
                                      toggleSidebar: { sidebarShown.toggle() },
                                      showLayout: path.isEmpty && layoutPages, search: $search, focus: $searchFocus, addMusic: { lib.pickMusic() })
                        }
                    }
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

    /// the sidebar and the page. macOS 13 and later use a NavigationSplitView; macOS 12 has no such view, so it is a plain row there.
    @ViewBuilder private var shell: some View {
        if #available(macOS 13, *) {
            NavigationSplitView(columnVisibility: Binding(get: { sidebarShown ? NavigationSplitViewVisibility.all : .detailOnly }, set: { sidebarShown = $0 != .detailOnly })) {
                sidebar.navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 280)
            } detail: {
                detailPage
            }
            // there is no window toolbar at all (it always drew a separate bar, most visibly in full screen): the title, the search box
            // and the buttons are part of the page's own top edge instead
            .toolbar(.hidden, for: .windowToolbar)
        } else {
            HStack(spacing: 0) {
                if sidebarShown { sidebar.listStyle(.sidebar).frame(width: 215); Divider() }
                detailPage
            }
        }
    }

    private func openPlayer() { searchFocus = false; withAnimation(.spring(response: 0.46, dampingFraction: 0.9)) { showPlayer = true } }
    private func closePlayer() { withAnimation(.spring(response: 0.42, dampingFraction: 0.92)) { showPlayer = false } }

    private func finishSearch() { search = ""; searchFocus = false }
    private func openSong(_ s: Song, _ list: [Song]) { player.play(s, in: list); finishSearch() }
    private func openAlbum(_ key: String) { nav = .albums; path.reset(); path.append(AlbumRef(key: key)); finishSearch() }
    private func openArtist(_ name: String) { nav = .artists; path.reset(); path.append(ArtistRef(name: name)); finishSearch() }
    private func searchWeb() {
        let q = search.trimmingCharacters(in: .whitespaces)
        YouTube.shared.query = q; YouTube.shared.type = "song"
        nav = .youtube; path.reset(); search = ""; searchFocus = false
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

/// the top edge of the page: sidebar button, back button, title, layout switch, search and Add Music, drawn straight on the page background
struct TopHeader: View {
    var title: String
    var canGoBack: Bool
    var back: () -> Void
    var toggleSidebar: () -> Void
    var showLayout: Bool
    @Binding var search: String
    var focus: FocusState<Bool>.Binding
    var addMusic: () -> Void
    @AppStorage("songsLayout") private var layout = "table"

    var body: some View {
        HStack(spacing: 14) {
            Button(action: toggleSidebar) { Image(systemName: "sidebar.left") }.buttonStyle(.plain).help("Show or hide the sidebar")
            if canGoBack { Button(action: back) { Image(systemName: "chevron.left") }.buttonStyle(.plain).help("Back") }
            Text(canGoBack ? "" : title).font(.system(size: 22, weight: .bold)).lineLimit(1)
            Spacer()
            if showLayout {
                Picker("Layout", selection: $layout) {
                    Image(systemName: "tablecells").tag("table")
                    Image(systemName: "list.bullet").tag("list")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 84).help("Table or list")
            }
            SearchField(text: $search, focus: focus)
            Button(action: addMusic) { Image(systemName: "plus") }.buttonStyle(.plain).help("Add a music folder or songs")
        }
        .font(.system(size: 15, weight: .semibold))
        .padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 8)
    }
}

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
        .background { Capsule().fill(Color.white.opacity(focus.wrappedValue ? 0.14 : 0.08)) }
    }
}

struct SearchDropdown: View {
    let query: String
    @ObservedObject var nav: SearchNav
    var openSong: (Song, [Song]) -> Void
    var openAlbum: (String) -> Void
    var openArtist: (String) -> Void
    var web: () -> Void
    var finish: () -> Void
    @EnvironmentObject var lib: Library
    @EnvironmentObject var player: Player
    @AppStorage("liveYt") private var liveYt = true
    @State private var yt: [YtResult] = []
    @State private var ytBusy = false
    @State private var hits = Hits()

    private struct Hits { var songs: [Song] = []; var albums: [AlbumInfo] = []; var artists: [ArtistInfo] = [] }

    /// matching thousands of songs is done off the main thread, a moment after the last key, using accent- and case-insensitive text
    nonisolated private static func search(_ songs: [Song], _ albums: [AlbumInfo], _ artists: [ArtistInfo], _ q: String) -> Hits {
        func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let f = fold(q)
        var h = Hits()
        h.songs = songs.filter { fold($0.title).contains(f) || fold($0.artist).contains(f) || fold($0.album).contains(f) }
        h.albums = albums.filter { fold($0.title).contains(f) || fold($0.artist).contains(f) }
        h.artists = artists.filter { fold($0.id).contains(f) }
        return h
    }

    private var q: String { query.trimmingCharacters(in: .whitespaces) }

    private struct Found {
        var songs: [Song] = []; var albums: [AlbumInfo] = []; var artists: [ArtistInfo] = []
        var shownSongs: [Song] = []; var shownAlbums: [AlbumInfo] = []; var shownArtists: [ArtistInfo] = []; var shownYt: [YtResult] = []
        var actions: [() -> Void] = []
    }

    private func found() -> Found {
        var f = Found()
        if !q.isEmpty { f.songs = hits.songs; f.albums = hits.albums; f.artists = hits.artists }
        f.shownSongs = Array(f.songs.prefix(6)); f.shownAlbums = Array(f.albums.prefix(3)); f.shownArtists = Array(f.artists.prefix(3)); f.shownYt = Array(yt.prefix(5))
        let all = f.songs
        for s in f.shownSongs { f.actions.append { openSong(s, all) } }
        for a in f.shownAlbums { f.actions.append { openAlbum(a.id) } }
        for a in f.shownArtists { f.actions.append { openArtist(a.id) } }
        for r in f.shownYt { f.actions.append { grab(r) } }
        return f
    }

    var body: some View {
        let f = found()
        let _ = setActions(f.actions)
        let o1 = f.shownSongs.count, o2 = o1 + f.shownAlbums.count, o3 = o2 + f.shownArtists.count

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
                        Text("↩").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().opacity(0.5)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if q.isEmpty {
                            Text("Search your songs, albums and artists").foregroundStyle(.secondary).font(.system(size: 12.5)).padding(16)
                        } else if f.songs.isEmpty && f.albums.isEmpty && f.artists.isEmpty && yt.isEmpty && !ytBusy {
                            Text("Nothing in your library matches “\(q)”").foregroundStyle(.secondary).font(.system(size: 12.5)).padding(16)
                        }
                        if !f.shownSongs.isEmpty {
                            header("Songs")
                            ForEach(Array(f.shownSongs.enumerated()), id: \.element.id) { i, s in
                                row(i, CoverView(song: s, size: 34, radius: 6), s.title, s.shownArtist + (s.album.isEmpty ? "" : " · " + s.album), s.id == player.current?.id) { openSong(s, f.songs) }
                            }
                        }
                        if !f.shownAlbums.isEmpty {
                            header("Albums")
                            ForEach(Array(f.shownAlbums.enumerated()), id: \.element.id) { i, a in
                                row(o1 + i, CoverView(song: a.cover, size: 34, radius: 6), a.title, a.artist, false) { openAlbum(a.id) }
                            }
                        }
                        if !f.shownArtists.isEmpty {
                            header("Artists")
                            ForEach(Array(f.shownArtists.enumerated()), id: \.element.id) { i, a in
                                row(o2 + i, CoverView(song: a.cover, size: 34, radius: 17), a.id, "\(a.songs.count) songs", false) { openArtist(a.id) }
                            }
                        }
                        if !f.shownYt.isEmpty || ytBusy {
                            HStack(spacing: 6) {
                                header("On YouTube Music")
                                if ytBusy { ProgressView().controlSize(.mini).padding(.top, 8) }
                            }
                            ForEach(Array(f.shownYt.enumerated()), id: \.element.id) { i, r in
                                row(o3 + i, YtThumb(url: r.thumb, size: 34, radius: 6), r.title, r.artist, false, trailing: "arrow.down.circle") { grab(r) }
                            }
                        }
                    }
                    .padding(.bottom, 6)
                }
                .onChange(of: nav.sel) { s in if s >= 0 { withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(s, anchor: .center) } } }
            }
            .frame(maxHeight: 380)
        }
        .frame(width: 400)
        .glass(18)
        .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
        .task(id: q) { await searchYouTube() }
        .task(id: q) {
            guard !q.isEmpty else { hits = Hits(); return }
            try? await Task.sleep(nanoseconds: 90_000_000)
            if Task.isCancelled { return }
            let songs = lib.songs, albums = lib.albums, artists = lib.artists, query = q
            let r = await Task.detached(priority: .userInitiated) { Self.search(songs, albums, artists, query) }.value
            if !Task.isCancelled { hits = r }
        }
    }

    private func setActions(_ a: [() -> Void]) { nav.actions = a }

    private func grab(_ r: YtResult) {
        Downloads.shared.lib = lib
        Downloads.shared.add([Track(id: r.id, title: r.title, artist: r.artist, album: r.album, thumb: r.thumb)], play: true)
        lib.flash("Downloading “\(r.title)”…")
        finish()
    }

    /// YouTube results appear under the library's once typing has paused for 0.4 s
    private func searchYouTube() async {
        yt = []; ytBusy = false
        guard liveYt, q.count >= 2 else { return }
        try? await Task.sleep(nanoseconds: 400_000_000)
        if Task.isCancelled { return }
        ytBusy = true
        let r = try? await YtEngine.shared.search(q, type: "song")
        if Task.isCancelled { return }
        ytBusy = false
        yt = (r ?? []).filter { $0.kind == "song" }
    }

    private func header(_ t: String) -> some View {
        Text(t).font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary).textCase(.uppercase).padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 2)
    }

    private func row<C: View>(_ index: Int, _ cover: C, _ title: String, _ sub: String, _ playing: Bool, trailing: String? = nil, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                cover
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1).foregroundStyle(playing ? player.accent : Color.primary)
                    Text(sub).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let t = trailing { Image(systemName: t).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 12).padding(.vertical, 4).contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(index == nav.sel ? player.accent.opacity(0.28) : Color.clear).padding(.horizontal, 4))
        }
        .buttonStyle(.plain)
        .id(index)
    }
}

// MARK: - sidebar

/// the Downloads line of the sidebar: only this little view redraws while downloads make progress
struct DownloadsRow: View {
    @ObservedObject var dl = Downloads.shared
    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text("Downloads")
                Spacer(minLength: 4)
                HStack(spacing: 3) {
                    Image(systemName: "arrow.down.circle")
                    Text("\(dl.active)").monospacedDigit()
                }.foregroundStyle(dl.active > 0 ? Color.accentColor : Color.secondary.opacity(0.7))
                HStack(spacing: 3) {
                    Image(systemName: "checkmark.circle")
                    Text("\(dl.finished)").monospacedDigit()
                }.foregroundStyle(dl.finished > 0 ? Color.green : Color.secondary.opacity(0.7))
            }.font(.system(size: 12))
        } icon: { Image(systemName: "tray.and.arrow.down") }
    }
}

struct SidebarView: View {
    @Binding var nav: Nav?
    @EnvironmentObject var lib: Library
    @EnvironmentObject var updater: Updater
    @State private var renaming: Playlist?
    @State private var dropOn: String?
    @State private var newName = ""
    @State private var editingSmart: SmartPlaylist?

    var body: some View {
        List(selection: $nav) {
            Section("Discover") {
                Label("Home", systemImage: "house").tag(Nav.home)
                Label("Replay", systemImage: "chart.bar.xaxis").tag(Nav.replay)
            }
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
                DownloadsRow().tag(Nav.downloads)
            }
            Section("Playlists") {
                ForEach(lib.playlists) { p in
                    Label(p.name, systemImage: "music.note.list").tag(Nav.playlist(p.id))
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 6).fill(dropOn == p.id ? Color.accentColor.opacity(0.35) : Color.clear))
                        .onDrag { SongDrag.provider(lib.songs(in: p), name: p.name) }
                        .onDrop(of: [SongDrag.type], isTargeted: Binding(get: { dropOn == p.id }, set: { on in if on { dropOn = p.id } else if dropOn == p.id { dropOn = nil } })) { providers in
                            SongDrag.ids(from: providers) { ids in
                                lib.add(ids, to: p.id)
                                lib.flash("Added \(ids.count) \(ids.count == 1 ? "song" : "songs") to \(p.name)")
                            }
                            return true
                        }
                        .contextMenu {
                            Button("Rename…") { newName = p.name; renaming = p }
                            Button("Duplicate") { lib.duplicate(p) }
                            Button("Export as M3U…") { lib.exportM3U(p) }
                            Button("Delete", role: .destructive) { if nav == .playlist(p.id) { nav = .songs }; lib.deletePlaylist(p.id) }
                        }
                }
                Button { lib.newPlaylist("New Playlist") } label: { Label("New Playlist", systemImage: "plus") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .onDrop(of: [SongDrag.type], isTargeted: nil) { providers in
                        SongDrag.ids(from: providers) { ids in
                            lib.newPlaylist("New Playlist", with: ids)
                            lib.flash("Made a new playlist with \(ids.count) \(ids.count == 1 ? "song" : "songs")")
                        }
                        return true
                    }
                Button { lib.importM3U() } label: { Label("Import Playlist…", systemImage: "square.and.arrow.down") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if updater.available != nil {
            VStack(spacing: 8) {
                if let r = updater.available {
                    Button { updater.showPrompt = true } label: {
                        Label("Update to \(r.version)", systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(10)
            }
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
    @Binding var path: AppPath
    @EnvironmentObject var lib: Library

    var body: some View {
        stack
            .id(nav)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.16), value: nav)
    }

    /// the page you are on, with the pages you went into on top of it (a NavigationStack on macOS 13 and later, a plain stack on macOS 12)
    @ViewBuilder private var stack: some View {
        if #available(macOS 13, *) {
            NavigationStack(path: Binding(get: { path.modern }, set: { path.modern = $0 })) {
                page
                    .navigationTitle(title)
                    .navigationDestination(for: AlbumRef.self) { AlbumDetail(key: $0.key) }
                    .navigationDestination(for: ArtistRef.self) { ArtistDetail(name: $0.name) }
                    .navigationDestination(for: YtCollection.self) { YtCollectionView(c: $0) }
                    .navigationDestination(for: YtArtistRef.self) { YtArtistView(a: $0) }
            }
        } else {
            LegacyStack(path: $path, root: page.navigationTitle(title))
        }
    }

    @ViewBuilder private var page: some View {
        switch nav {
        case .home: HomeView()
        case .replay: ReplayView()
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
        case .playlist(let id):
            if let p = lib.playlists.first(where: { $0.id == id }) { SongTable(songs: lib.songs(in: p), search: search) } else { Text("This playlist is gone.").foregroundStyle(.secondary) }
        }
    }

    private var title: String {
        switch nav {
        case .home: return "Home"
        case .replay: return "Replay"
        case .songs: return "Songs"
        case .recent: return "Recently Added"
        case .albums: return "Albums"
        case .artists: return "Artists"
        case .favorites: return "Favorites"
        case .duplicates: return "Duplicates"
        case .smart(let id): return lib.smartPlaylist(id)?.name ?? "Smart Playlist"
        case .youtube: return "Search & Download"
        case .downloads: return "Downloads"
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
    @AppStorage("glassTint") private var glassTint = 1.0
    @AppStorage("barRadius") private var barRadius = 26.0
    @AppStorage("barCompact") private var compact = false
    @AppStorage("barHeart") private var showHeart = true
    @AppStorage("barQueue") private var showQueue = true
    var open: () -> Void

    var body: some View {
        if let s = player.current {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    CoverView(song: s, size: compact ? 36 : 46, radius: compact ? 8 : 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Text(s.shownArtist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            .onTapGesture { NotificationCenter.default.post(name: .goRef, object: ArtistRef(name: s.artistKey)) }
                    }
                    Spacer(minLength: 12)
                    if showHeart {
                        Button { lib.toggleFav(s) } label: { Image(systemName: lib.isFav(s) ? "heart.fill" : "heart").foregroundStyle(lib.isFav(s) ? player.accent : Color.secondary) }
                            .buttonStyle(.plain).help("Favorite")
                    }
                    TransportButtons()
                    if showQueue { QueueButton().foregroundStyle(.secondary).padding(.leading, 4) }
                    Button { open() } label: { Image(systemName: "chevron.up").font(.system(size: 13, weight: .bold)) }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.leading, 6)
                }
                .padding(.horizontal, 14).padding(.top, compact ? 7 : 9).padding(.bottom, compact ? 7 : 4)
                if !compact { SeekBar(clock: player.clock, duration: s.duration) { player.seek(to: $0) }.padding(.horizontal, 16).padding(.bottom, 4) }
            }
            .frame(maxWidth: compact ? 560 : 720)
            .glass(CGFloat(barRadius), tint: glassTint > 0.01 ? player.accent.opacity(glassTint) : nil)
            .contentShape(RoundedRectangle(cornerRadius: CGFloat(barRadius), style: .continuous))
            .onTapGesture(perform: open)
            .padding(.horizontal, 18).padding(.bottom, 14)
            .frame(maxWidth: .infinity)
        }
    }
}
