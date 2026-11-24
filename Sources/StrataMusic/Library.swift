import Foundation
import AVFoundation
import AppKit

struct Song: Identifiable, Codable, Hashable {
    var id: String
    var path: String
    var title: String
    var artist: String
    var album: String
    var albumArtist: String
    var track: Int
    var year: String
    var duration: Double
    var cover: String          // file name inside the covers folder ("" = none)
    var added: Double

    var url: URL { URL(fileURLWithPath: path) }
    var ext: String { url.pathExtension.lowercased() }
    var shownArtist: String { artist.isEmpty ? "Unknown Artist" : artist }
    var shownAlbum: String { album.isEmpty ? "Unknown Album" : album }
    var albumKey: String { (albumArtist.isEmpty ? primaryArtist(artist) : albumArtist) + "||" + album }
    var artistKey: String { let a = primaryArtist(albumArtist.isEmpty ? artist : albumArtist); return a.isEmpty ? "Unknown Artist" : a }
}

struct Playlist: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var songIDs: [String]
}

struct AlbumInfo: Identifiable, Hashable {
    var id: String
    var title: String
    var artist: String
    var year: String
    var songs: [Song]
    var cover: Song? { songs.first { !$0.cover.isEmpty } ?? songs.first }
}

struct ArtistInfo: Identifiable, Hashable {
    var id: String
    var songs: [Song]
    var albums: [AlbumInfo]
    var cover: Song? { songs.first { !$0.cover.isEmpty } ?? songs.first }
}

// MARK: - the part that touches the disk (not tied to the main thread)

enum Disk {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Strata Music", isDirectory: true)
        try? FileManager.default.createDirectory(at: d.appendingPathComponent("covers", isDirectory: true), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: d.appendingPathComponent("lyrics", isDirectory: true), withIntermediateDirectories: true)
        return d
    }()

    static let playable: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aif", "aiff", "alac", "caf", "mp4"]
    static let notYet: Set<String> = ["opus", "ogg", "webm", "oga"]

    /// every audio file under [url] (or [url] itself); the second number counts files this Mac can't play yet (Opus, Ogg, WebM)
    static func audioFiles(in url: URL) -> (files: [URL], skipped: Int) {
        var files: [URL] = []; var skipped = 0
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return ([], 0) }
        func consider(_ u: URL) {
            let e = u.pathExtension.lowercased()
            if playable.contains(e) { files.append(u) } else if notYet.contains(e) { skipped += 1 }
        }
        if isDir.boolValue {
            if let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                for case let u as URL in en { consider(u) }
            }
        } else { consider(url) }
        return (files, skipped)
    }

    static func readSong(_ url: URL) async -> Song? {
        let asset = AVURLAsset(url: url)
        guard let d = try? await asset.load(.duration) else { return nil }
        let secs = CMTimeGetSeconds(d)
        guard secs.isFinite, secs > 0.5 else { return nil }
        let common = (try? await asset.load(.commonMetadata)) ?? []
        let all = (try? await asset.load(.metadata)) ?? []

        func text(_ items: [AVMetadataItem], _ id: AVMetadataIdentifier) async -> String {
            for it in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id) {
                if let s = try? await it.load(.stringValue), !s.isEmpty { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            return ""
        }
        let base = url.deletingPathExtension().lastPathComponent
        var title = await text(common, .commonIdentifierTitle)
        let artist = await text(common, .commonIdentifierArtist)
        let album = await text(common, .commonIdentifierAlbumName)
        var albumArtist = await text(all, .iTunesMetadataAlbumArtist)
        if albumArtist.isEmpty { albumArtist = await text(all, .id3MetadataBand) }
        let created = await text(common, .commonIdentifierCreationDate)
        let year = String(created.prefix(4)).allSatisfy({ $0.isNumber }) ? String(created.prefix(4)) : ""
        var track = 0
        let trackText = await text(all, .id3MetadataTrackNumber)
        if let first = trackText.split(separator: "/").first, let n = Int(first) { track = n }
        if title.isEmpty {
            // "01 - Song" or "01 Song": the number is the track, the rest the title
            let digits = base.prefix(while: { $0.isNumber })
            if !digits.isEmpty, digits.count <= 3, let n = Int(digits) {
                var rest = String(base.dropFirst(digits.count)).trimmingCharacters(in: CharacterSet(charactersIn: " -._"))
                if rest.isEmpty { rest = base } else if track == 0 { track = n }
                title = rest
            } else { title = base }
        }
        // the picture inside the file
        var cover = ""
        for it in AVMetadataItem.metadataItems(from: common, filteredByIdentifier: .commonIdentifierArtwork) {
            if let data = try? await it.load(.dataValue), data.count > 200 {
                let name = fnv(data.prefix(8192)) + "-\(data.count).img"
                let dest = dir.appendingPathComponent("covers/\(name)")
                if !FileManager.default.fileExists(atPath: dest.path) { try? data.write(to: dest) }
                cover = name
                break
            }
        }
        return Song(id: fnv(Data(url.path.utf8)), path: url.path, title: title, artist: artist, album: album, albumArtist: albumArtist, track: track, year: year, duration: secs, cover: cover, added: Date().timeIntervalSince1970)
    }
}

// MARK: - the library

@MainActor
final class Library: ObservableObject {
    @Published private(set) var songs: [Song] = []
    @Published private(set) var albums: [AlbumInfo] = []
    @Published private(set) var artists: [ArtistInfo] = []
    @Published var favorites: Set<String> = []
    @Published var playlists: [Playlist] = []
    @Published var folders: [String] = []
    @Published var status: String = ""

    private(set) var byID: [String: Song] = [:]

    private struct Saved: Codable {
        var songs: [Song]
        var favorites: [String]
        var playlists: [Playlist]
        var folders: [String]
    }

    init() {
        if let d = try? Data(contentsOf: Disk.dir.appendingPathComponent("library.json")),
           let s = try? JSONDecoder().decode(Saved.self, from: d) {
            songs = s.songs.filter { FileManager.default.fileExists(atPath: $0.path) }
            favorites = Set(s.favorites); playlists = s.playlists; folders = s.folders
        }
        rebuild()
    }

    func save() {
        let s = Saved(songs: songs, favorites: Array(favorites), playlists: playlists, folders: folders)
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: Disk.dir.appendingPathComponent("library.json"), options: .atomic) }
    }

    private func rebuild() {
        byID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let grouped = Dictionary(grouping: songs, by: { $0.albumKey })
        albums = grouped.map { key, list in
            let sorted = list.sorted { ($0.track == 0 ? 9999 : $0.track, $0.title) < ($1.track == 0 ? 9999 : $1.track, $1.title) }
            let f = sorted[0]
            return AlbumInfo(id: key, title: f.shownAlbum, artist: f.artistKey, year: f.year, songs: sorted)
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        let byArtist = Dictionary(grouping: songs, by: { $0.artistKey })
        artists = byArtist.map { name, list in
            ArtistInfo(id: name, songs: list, albums: albums.filter { $0.artist == name })
        }.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    // MARK: adding music

    func pickMusic() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = true; p.allowsMultipleSelection = true
        p.message = "Choose a music folder, or songs"; p.prompt = "Add"
        if p.runModal() == .OK { importURLs(p.urls, remember: true) }
    }

    func importURLs(_ urls: [URL], remember: Bool = false, thenPlay: Bool = false) {
        Task {
            status = "Looking for music…"
            var files: [URL] = []; var skipped = 0
            for u in urls {
                let found = await Task.detached { Disk.audioFiles(in: u) }.value
                files += found.files; skipped += found.skipped
                if remember, !folders.contains(u.path) { folders.append(u.path) }
            }
            let known = Set(songs.map { $0.path })
            let fresh = files.filter { !known.contains($0.path) }
            var batch: [Song] = []
            for (i, f) in fresh.enumerated() {
                status = "Reading \(i + 1) of \(fresh.count)…"
                if let s = await Disk.readSong(f) { batch.append(s) }
                if batch.count >= 40 { songs.append(contentsOf: batch); batch = []; rebuild() }
            }
            if !batch.isEmpty { songs.append(contentsOf: batch); rebuild() }
            save()
            var msg = fresh.isEmpty ? "Nothing new" : "Added \(fresh.count) songs"
            if skipped > 0 { msg += " · \(skipped) Opus/Ogg/WebM files can't be played on the Mac yet" }
            status = msg
            if thenPlay, let first = files.first, let s = songs.first(where: { $0.path == first.path }) { Player.shared.play(s, in: [s]) }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if status == msg { status = "" }
        }
    }

    func rescan() {
        let urls = folders.map { URL(fileURLWithPath: $0) }
        songs = songs.filter { FileManager.default.fileExists(atPath: $0.path) }
        rebuild()
        if !urls.isEmpty { importURLs(urls) } else { save() }
    }

    func remove(_ ids: Set<String>) {
        songs.removeAll { ids.contains($0.id) }
        for i in playlists.indices { playlists[i].songIDs.removeAll { ids.contains($0) } }
        rebuild(); save()
    }

    // MARK: favourites and playlists

    func isFav(_ s: Song) -> Bool { favorites.contains(s.id) }
    func toggleFav(_ s: Song) { if favorites.contains(s.id) { favorites.remove(s.id) } else { favorites.insert(s.id) }; save() }
    var favoriteSongs: [Song] { songs.filter { favorites.contains($0.id) } }

    func newPlaylist(_ name: String, with ids: [String] = []) {
        playlists.append(Playlist(id: UUID().uuidString, name: name.isEmpty ? "New Playlist" : name, songIDs: ids)); save()
    }
    func add(_ ids: [String], to playlist: String) {
        guard let i = playlists.firstIndex(where: { $0.id == playlist }) else { return }
        for id in ids where !playlists[i].songIDs.contains(id) { playlists[i].songIDs.append(id) }
        save()
    }
    func deletePlaylist(_ id: String) { playlists.removeAll { $0.id == id }; save() }
    func rename(_ id: String, to name: String) { if let i = playlists.firstIndex(where: { $0.id == id }) { playlists[i].name = name; save() } }
    func songs(in p: Playlist) -> [Song] { p.songIDs.compactMap { byID[$0] } }
}
