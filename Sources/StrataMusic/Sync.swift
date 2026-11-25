import SwiftUI
import AppKit

// MARK: - the file each device writes

struct SyncSong: Codable, Equatable { var plays: Int; var skips: Int; var lastPlayed: Double }
struct SyncFav: Codable, Equatable { var fav: Bool; var at: Double }
struct SyncPlaylist: Codable, Equatable { var keys: [String]; var updated: Double }

struct SyncFile: Codable {
    var device: String
    var deviceName: String
    var written: Double
    var songs: [String: SyncSong] = [:]
    var fav: [String: SyncFav] = [:]
    var playlists: [String: SyncPlaylist] = [:]
    var deleted: [String: Double] = [:]
}

/// what this device knew at the end of the last sync (so changes since then can be told apart)
struct SyncState: Codable {
    var device = UUID().uuidString
    var favSnapshot: [String] = []
    var favTimes: [String: SyncFav] = [:]
    var playlistHash: [String: String] = [:]
    var playlistTimes: [String: Double] = [:]
    var playlistNames: [String] = []
    var deleted: [String: Double] = [:]
    var extraKeys: [String: [String]] = [:]     // songs in a playlist that this Mac doesn't have
}

/// the rules for combining devices; no I/O, so they're easy to test
enum SyncMerge {
    /// play counts only go up, so the largest one is the truth (adding them would count the same play twice)
    static func plays(_ counts: [Int]) -> Int { counts.max() ?? 0 }

    /// a like or an un-like: the most recent one wins
    static func fav(_ recs: [SyncFav]) -> SyncFav? { recs.max { $0.at < $1.at } }

    /// a playlist: the most recently changed copy wins, unless it was deleted after that
    static func playlist(_ copies: [SyncPlaylist], deleted: [Double]) -> SyncPlaylist? {
        guard let best = copies.max(by: { $0.updated < $1.updated }) else { return nil }
        if let d = deleted.max(), d > best.updated { return nil }
        return best
    }

    /// "title|artist", lowercased and tidied: the same song on two Macs gets the same key
    static func key(title: String, artist: String) -> String {
        func tidy(_ s: String) -> String {
            s.lowercased().folding(options: [.diacriticInsensitive], locale: nil).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        return tidy(title) + "|" + tidy(primaryArtist(artist))
    }
}

@MainActor
final class Sync: ObservableObject {
    static let shared = Sync()
    @Published private(set) var folder: String? = UserDefaults.standard.string(forKey: "syncFolder")
    @Published private(set) var status = ""
    @Published private(set) var syncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var others: [String] = []     // the other devices seen in the folder

    private var timer: Task<Void, Never>?
    private var stateURL: URL { Disk.dir.appendingPathComponent("sync-state.json") }
    private var dir: URL? { folder.map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("Strata Sync", isDirectory: true) } }

    func pick() {
        let p = NSOpenPanel()
        p.message = "Choose a folder that all your devices can see (iCloud Drive, Dropbox, Syncthing…)"
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        guard p.runModal() == .OK, let u = p.url else { return }
        folder = u.path
        UserDefaults.standard.set(u.path, forKey: "syncFolder")
        start()
        if let lib = Library.main { Task { await syncNow(lib) } }
    }

    func turnOff() {
        folder = nil; timer?.cancel(); timer = nil; status = ""; others = []
        UserDefaults.standard.removeObject(forKey: "syncFolder")
    }

    /// once on launch, then every ten minutes while the app is open
    func start() {
        timer?.cancel()
        guard folder != nil else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            while !Task.isCancelled {
                if let self = self, let lib = Library.main { await self.syncNow(lib, quiet: true) }
                try? await Task.sleep(nanoseconds: 600_000_000_000)
            }
        }
    }

    func syncNow(_ lib: Library, quiet: Bool = false) async {
        guard !syncing, let dir = dir else { return }
        syncing = true; defer { syncing = false }
        do {
            let n = try merge(lib, dir)
            lastSync = Date()
            status = n == 0 ? "Up to date" : "Merged \(n) change\(n == 1 ? "" : "s")"
            if n > 0 { EngineLog.shared.add("Sync: \(status)") }
        } catch {
            status = "Couldn't sync: \(error.localizedDescription)"
            EngineLog.shared.add("Sync failed: \(error.localizedDescription)")
        }
    }

    private func merge(_ lib: Library, _ dir: URL) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var st = (try? JSONDecoder().decode(SyncState.self, from: Data(contentsOf: stateURL))) ?? SyncState()
        let now = Date().timeIntervalSince1970
        var changes = 0

        // keys for this Mac's songs
        var keyToID: [String: String] = [:], idToKey: [String: String] = [:]
        for s in lib.songs {
            let k = SyncMerge.key(title: s.title, artist: s.artist)
            idToKey[s.id] = k
            if keyToID[k] == nil { keyToID[k] = s.id }
        }

        // 1. what changed on this Mac since the last sync
        let favNow = Set(lib.favorites.compactMap { idToKey[$0] })
        var favs = st.favTimes
        for k in favNow where !st.favSnapshot.contains(k) { favs[k] = SyncFav(fav: true, at: now) }
        for k in st.favSnapshot where !favNow.contains(k) && keyToID[k] != nil { favs[k] = SyncFav(fav: false, at: now) }

        var mine: [String: SyncSong] = [:]
        for s in lib.songs {
            guard let k = idToKey[s.id] else { continue }
            let cur = mine[k] ?? SyncSong(plays: 0, skips: 0, lastPlayed: 0)
            mine[k] = SyncSong(plays: cur.plays + (s.plays ?? 0), skips: cur.skips + (s.skips ?? 0), lastPlayed: max(cur.lastPlayed, s.lastPlayed ?? 0))
        }

        var lists: [String: SyncPlaylist] = [:]
        var deleted = st.deleted
        for p in lib.playlists {
            let keys = p.songIDs.compactMap { idToKey[$0] } + (st.extraKeys[p.name] ?? [])
            let h = fnv(Data(keys.joined(separator: "\n").utf8))
            let t = st.playlistHash[p.name] == h ? (st.playlistTimes[p.name] ?? now) : now
            lists[p.name] = SyncPlaylist(keys: keys, updated: t)
            if let d = deleted[p.name], t > d { deleted[p.name] = nil }      // made again after it was deleted
        }
        for name in st.playlistNames where lists[name] == nil { deleted[name] = now }

        // 2. what the other devices wrote
        var remotes: [SyncFile] = []
        for u in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where u.pathExtension == "json" {
            guard let f = try? JSONDecoder().decode(SyncFile.self, from: Data(contentsOf: u)), f.device != st.device else { continue }
            remotes.append(f)
        }
        others = remotes.map { $0.deviceName }

        // 3. likes
        for k in Set(favs.keys).union(remotes.flatMap { $0.fav.keys }) {
            let recs = [favs[k]].compactMap { $0 } + remotes.compactMap { $0.fav[k] }
            guard let win = SyncMerge.fav(recs) else { continue }
            favs[k] = win
            if let id = keyToID[k] {
                if win.fav && !lib.favorites.contains(id) { lib.favorites.insert(id); changes += 1 }
                if !win.fav && lib.favorites.contains(id) { lib.favorites.remove(id); changes += 1 }
            }
        }

        // 4. play counts
        var touched = false
        for (k, id) in keyToID {
            let theirs = remotes.compactMap { $0.songs[k] }
            guard !theirs.isEmpty, let i = lib.songs.firstIndex(where: { $0.id == id }) else { continue }
            let plays = SyncMerge.plays(theirs.map { $0.plays } + [mine[k]?.plays ?? 0])
            let skips = SyncMerge.plays(theirs.map { $0.skips } + [mine[k]?.skips ?? 0])
            let last = max(theirs.map { $0.lastPlayed }.max() ?? 0, mine[k]?.lastPlayed ?? 0)
            if plays > (mine[k]?.plays ?? 0) || skips > (mine[k]?.skips ?? 0) || last > (mine[k]?.lastPlayed ?? 0) {
                // this song's total across duplicates is already in [mine]; only raise the first copy by the difference
                lib.songs[i].plays = (lib.songs[i].plays ?? 0) + max(0, plays - (mine[k]?.plays ?? 0))
                lib.songs[i].skips = (lib.songs[i].skips ?? 0) + max(0, skips - (mine[k]?.skips ?? 0))
                if last > 0 { lib.songs[i].lastPlayed = max(lib.songs[i].lastPlayed ?? 0, last) }
                touched = true; changes += 1
            }
        }
        if touched { lib.rebuildNow() }
        let afterPlays = lib.songs.reduce(into: [String: SyncSong]()) { acc, s in
            guard let k = idToKey[s.id] else { return }
            let cur = acc[k] ?? SyncSong(plays: 0, skips: 0, lastPlayed: 0)
            acc[k] = SyncSong(plays: cur.plays + (s.plays ?? 0), skips: cur.skips + (s.skips ?? 0), lastPlayed: max(cur.lastPlayed, s.lastPlayed ?? 0))
        }

        // 5. playlists
        for r in remotes { for (n, t) in r.deleted { deleted[n] = max(deleted[n] ?? 0, t) } }
        var extra: [String: [String]] = [:]
        for name in Set(lists.keys).union(remotes.flatMap { $0.playlists.keys }) {
            let copies = [lists[name]].compactMap { $0 } + remotes.compactMap { $0.playlists[name] }
            let win = SyncMerge.playlist(copies, deleted: [deleted[name]].compactMap { $0 })
            let idx = lib.playlists.firstIndex { $0.name == name }
            guard let w = win else {
                if let i = idx { lib.playlists.remove(at: i); lists[name] = nil; changes += 1 }
                continue
            }
            if w != lists[name] {
                let ids = w.keys.compactMap { keyToID[$0] }
                extra[name] = w.keys.filter { keyToID[$0] == nil }
                if let i = idx { lib.playlists[i].songIDs = ids }
                else { lib.playlists.append(Playlist(id: UUID().uuidString, name: name, songIDs: ids)) }
                changes += 1
            } else { extra[name] = st.extraKeys[name] ?? [] }
            lists[name] = w
        }

        // 6. remember where we are, and write this Mac's file
        var hashes: [String: String] = [:]
        for p in lib.playlists {
            let keys = p.songIDs.compactMap { idToKey[$0] } + (extra[p.name] ?? [])
            hashes[p.name] = fnv(Data(keys.joined(separator: "\n").utf8))
            if lists[p.name] == nil { lists[p.name] = SyncPlaylist(keys: keys, updated: now) }
        }
        st.favSnapshot = lib.favorites.compactMap { idToKey[$0] }
        st.favTimes = favs
        st.playlistHash = hashes
        st.playlistTimes = lists.mapValues { $0.updated }
        st.playlistNames = lib.playlists.map { $0.name }
        st.deleted = deleted
        st.extraKeys = extra
        if let d = try? JSONEncoder().encode(st) { try? d.write(to: stateURL, options: .atomic) }

        let out = SyncFile(device: st.device, deviceName: Host.current().localizedName ?? "This Mac", written: now, songs: afterPlays, fav: favs, playlists: lists, deleted: deleted)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        try enc.encode(out).write(to: dir.appendingPathComponent("\(st.device).json"), options: .atomic)

        if changes > 0 { lib.save() }
        return changes
    }
}

struct SyncSettings: View {
    @EnvironmentObject var lib: Library
    @ObservedObject var sync = Sync.shared

    var body: some View {
        Form {
            Section("Sync between your devices") {
                if let f = sync.folder {
                    HStack { Image(systemName: "folder"); Text(f).lineLimit(1).truncationMode(.middle); Spacer() }
                    HStack {
                        Button(sync.syncing ? "Syncing…" : "Sync Now") { Task { await sync.syncNow(lib) } }.disabled(sync.syncing)
                        Button("Change Folder…") { sync.pick() }
                        Button("Turn Off", role: .destructive) { sync.turnOff() }
                    }
                    if !sync.status.isEmpty { Text(sync.status + (sync.lastSync.map { " · " + $0.formatted(date: .omitted, time: .shortened) } ?? "")).foregroundStyle(.secondary) }
                    if !sync.others.isEmpty { Text("Also seen: " + sync.others.joined(separator: ", ")).foregroundStyle(.secondary) }
                } else {
                    Button("Choose a Folder…") { sync.pick() }
                }
                Text("Likes, playlists and play counts are shared through one small file per device in a folder you pick. Use any folder your devices share: iCloud Drive, Dropbox, Syncthing. There's no server. Songs themselves aren't copied, and songs are matched by title and artist. Smart playlists don't sync yet.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .groupedForm()
    }
}
