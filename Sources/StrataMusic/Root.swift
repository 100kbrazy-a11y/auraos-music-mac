import SwiftUI
import AppKit

enum Nav: Hashable {
    case songs, albums, artists, favorites
    case playlist(String)
}

struct RootView: View {
    @EnvironmentObject var lib: Library
    @EnvironmentObject var player: Player
    @EnvironmentObject var updater: Updater
    @State private var nav: Nav? = .songs
    @State private var showPlayer = false
    @State private var search = ""
    @State private var dropping = false

    var body: some View {
        ZStack {
            NavigationSplitView {
                SidebarView(nav: $nav)
                    .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 280)
            } detail: {
                DetailRoot(nav: nav ?? .songs, search: search)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if player.current != nil { NowPlayingBar(open: openPlayer) }
                    }
                    .overlay(alignment: .top) {
                        if !lib.status.isEmpty {
                            Text(lib.status).font(.system(size: 12, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 7).glass(16).padding(.top, 8)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
            }
            .searchable(text: $search, placement: .toolbar, prompt: "Search your library")
            .toolbar {
                ToolbarItem(placement: .automatic) { Button { lib.pickMusic() } label: { Label("Add Music", systemImage: "plus") }.help("Add a music folder or songs") }
            }
            .animation(.easeInOut(duration: 0.2), value: lib.status)

            if showPlayer {
                FullPlayerView(close: closePlayer)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in lib.importURLs(urls, remember: true); return true } isTargeted: { dropping = $0 }
        .overlay { if dropping { RoundedRectangle(cornerRadius: 14).strokeBorder(player.accent, lineWidth: 3).padding(6).allowsHitTesting(false) } }
        .background(Color(red: 0.07, green: 0.07, blue: 0.08))
        .overlay { UpdatePrompt() }
        .onReceive(NotificationCenter.default.publisher(for: .openPlayer)) { _ in openPlayer() }
    }

    private func openPlayer() { withAnimation(.spring(response: 0.46, dampingFraction: 0.9)) { showPlayer = true } }
    private func closePlayer() { withAnimation(.spring(response: 0.42, dampingFraction: 0.92)) { showPlayer = false } }
}

extension Notification.Name { static let openPlayer = Notification.Name("strata.openPlayer") }

// MARK: - sidebar

struct SidebarView: View {
    @Binding var nav: Nav?
    @EnvironmentObject var lib: Library
    @EnvironmentObject var updater: Updater
    @State private var renaming: Playlist?
    @State private var newName = ""

    var body: some View {
        List(selection: $nav) {
            Section("Library") {
                Label("Songs", systemImage: "music.note").tag(Nav.songs)
                Label("Albums", systemImage: "square.stack").tag(Nav.albums)
                Label("Artists", systemImage: "music.mic").tag(Nav.artists)
                Label("Favorites", systemImage: "heart").tag(Nav.favorites)
            }
            Section("Playlists") {
                ForEach(lib.playlists) { p in
                    Label(p.name, systemImage: "music.note.list").tag(Nav.playlist(p.id))
                        .contextMenu {
                            Button("Rename…") { newName = p.name; renaming = p }
                            Button("Delete", role: .destructive) { if nav == .playlist(p.id) { nav = .songs }; lib.deletePlaylist(p.id) }
                        }
                }
                Button { lib.newPlaylist("New Playlist") } label: { Label("New Playlist", systemImage: "plus") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if let r = updater.available {
                Button { updater.showPrompt = true } label: {
                    Label("Update to \(r.version)", systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).padding(10)
            }
        }
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
    @EnvironmentObject var lib: Library

    var body: some View {
        NavigationStack {
            Group {
                switch nav {
                case .songs: SongTable(songs: lib.songs, search: search)
                case .albums: AlbumsView(search: search)
                case .artists: ArtistsView(search: search)
                case .favorites: SongTable(songs: lib.favoriteSongs, search: search)
                case .playlist(let id):
                    if let p = lib.playlists.first(where: { $0.id == id }) { SongTable(songs: lib.songs(in: p), search: search) } else { Text("This playlist is gone.").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(title)
            .navigationDestination(for: AlbumRef.self) { AlbumDetail(key: $0.key) }
            .navigationDestination(for: ArtistRef.self) { ArtistDetail(name: $0.name) }
        }
        .id(nav)
    }

    private var title: String {
        switch nav {
        case .songs: return "Songs"
        case .albums: return "Albums"
        case .artists: return "Artists"
        case .favorites: return "Favorites"
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
    var open: () -> Void

    var body: some View {
        if let s = player.current {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    CoverView(song: s, size: 46, radius: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Text(s.shownArtist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    TransportButtons()
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
