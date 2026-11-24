import Foundation
import SwiftUI
import AppKit
import CoreServices
import UniformTypeIdentifiers

// MARK: - iTunes lookup (song info and covers)

enum ITunes {
    struct Hit: Identifiable { var id: Int; var title: String; var artist: String; var album: String; var albumArtist: String; var year: String; var track: Int; var art: String }

    private static func get(_ url: String) async -> [[String: Any]] {
        guard let u = URL(string: url) else { return [] }
        var req = URLRequest(url: u); req.timeoutInterval = 12; req.setValue("Strata Music for Mac", forHTTPHeaderField: "User-Agent")
        guard let (d, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
        return j["results"] as? [[String: Any]] ?? []
    }

    private static func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?.replacingOccurrences(of: "&", with: "%26") ?? s }

    static func songs(_ term: String) async -> [Hit] {
        let r = await get("https://itunes.apple.com/search?term=\(enc(term))&entity=song&limit=8")
        return r.enumerated().compactMap { i, o in
            guard let t = o["trackName"] as? String else { return nil }
            let year = String(((o["releaseDate"] as? String) ?? "").prefix(4))
            return Hit(id: i, title: t, artist: o["artistName"] as? String ?? "", album: o["collectionName"] as? String ?? "", albumArtist: "", year: year,
                       track: o["trackNumber"] as? Int ?? 0, art: big(o["artworkUrl100"] as? String ?? ""))
        }
    }

    static func album(_ term: String) async -> String? {
        let r = await get("https://itunes.apple.com/search?term=\(enc(term))&entity=album&limit=3")
        return r.compactMap { $0["artworkUrl100"] as? String }.first.map(big)
    }

    static func big(_ u: String) -> String { u.replacingOccurrences(of: "100x100bb", with: "1000x1000bb") }

    static func image(_ url: String) async -> Data? {
        guard let u = URL(string: url), let (d, r) = try? await URLSession.shared.data(from: u), (r as? HTTPURLResponse)?.statusCode == 200, d.count > 500 else { return nil }
        return d
    }
}

// MARK: - edit info

struct EditInfoSheet: View {
    let song: Song
    @EnvironmentObject var lib: Library
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var albumArtist = ""
    @State private var year = ""
    @State private var track = ""
    @State private var cover: Data?
    @State private var coverChanged = false
    @State private var writeFile = true
    @State private var busy = false
    @State private var note = ""
    @State private var hits: [ITunes.Hit] = []
    @State private var showHits = false

    private var taggable: Bool { ["m4a", "mp4", "aac"].contains(song.ext) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Info").font(.title2.weight(.bold))
            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 8) {
                    Group {
                        if let d = cover, let img = NSImage(data: d) { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill) }
                        else { CoverView(song: song, size: 150, radius: 12) }
                    }
                    .frame(width: 150, height: 150).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Menu("Cover") {
                        Button("Choose a File…") { chooseCover() }
                        Button("Paste") { if let img = NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage, let t = img.tiffRepresentation, let b = NSBitmapImageRep(data: t)?.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) { cover = b; coverChanged = true } }
                        Button("Find Online") { Task { await findCover() } }
                    }.frame(width: 150)
                }
                Form {
                    TextField("Title", text: $title)
                    TextField("Artist", text: $artist)
                    TextField("Album", text: $album)
                    TextField("Album artist", text: $albumArtist)
                    HStack { TextField("Year", text: $year); TextField("Track", text: $track) }
                }
                .formStyle(.columns)
            }
            HStack {
                Button { Task { await lookUp() } } label: { Label("Look Up Song Info…", systemImage: "magnifyingglass") }.disabled(busy)
                Spacer()
                if taggable { Toggle("Also write into the file", isOn: $writeFile).toggleStyle(.checkbox) }
            }
            if !taggable { Text("These changes are saved in your library. This kind of file can't have tags written into it.").font(.callout).foregroundStyle(.secondary) }
            if showHits { hitsList }
            if !note.isEmpty { Text(note).font(.callout).foregroundStyle(.orange) }
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { Task { await save() } }.keyboardShortcut(.defaultAction).disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22).frame(width: 560)
        .onAppear { title = song.title; artist = song.artist; album = song.album; albumArtist = song.albumArtist; year = song.year; track = song.track > 0 ? "\(song.track)" : "" }
    }

    private var hitsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(hits.isEmpty ? "Nothing found." : "Use this info?").font(.headline)
            ForEach(hits.prefix(5)) { h in
                Button { apply(h) } label: {
                    HStack { VStack(alignment: .leading) { Text(h.title).fontWeight(.medium); Text([h.artist, h.album, h.year].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text("Use").foregroundStyle(.tint) }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
    }

    private func apply(_ h: ITunes.Hit) {
        title = h.title; artist = h.artist; album = h.album; year = h.year; if h.track > 0 { track = "\(h.track)" }
        showHits = false
        Task { if let d = await ITunes.image(h.art) { cover = d; coverChanged = true } }
    }

    private func lookUp() async {
        busy = true; defer { busy = false }
        hits = await ITunes.songs("\(title) \(artist)"); showHits = true
    }

    private func findCover() async {
        busy = true; defer { busy = false }
        if let u = await ITunes.album("\(album.isEmpty ? title : album) \(artist)"), let d = await ITunes.image(u) { cover = d; coverChanged = true; note = "" }
        else { note = "No cover found online for this one." }
    }

    private func chooseCover() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.image]; p.canChooseDirectories = false
        if p.runModal() == .OK, let u = p.url, let d = try? Data(contentsOf: u) { cover = d; coverChanged = true }
    }

    private func save() async {
        busy = true; note = ""; defer { busy = false }
        var s = song
        s.title = title.trimmingCharacters(in: .whitespaces); s.artist = artist; s.album = album; s.albumArtist = albumArtist; s.year = year; s.track = Int(track) ?? 0
        if coverChanged, let d = cover { s.cover = Disk.saveCover(d) }
        if taggable && writeFile {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("strata-tag-\(UUID().uuidString).m4a")
            do {
                var t = Track(id: s.id, title: s.title, artist: s.artist, album: s.album, thumb: "")
                t.albumArtist = s.albumArtist; t.year = s.year
                var coverData = coverChanged ? cover : nil
                if coverData == nil, !s.cover.isEmpty { coverData = try? Data(contentsOf: Disk.dir.appendingPathComponent("covers/\(s.cover)")) }
                try await Downloads.tag(song.url, to: tmp, t, coverData)
                _ = try FileManager.default.replaceItemAt(song.url, withItemAt: tmp)
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                note = "Saved in your library, but the file itself couldn't be changed (\(error.localizedDescription))."
                lib.updateSong(s); return
            }
        }
        lib.updateSong(s)
        dismiss()
    }
}

// MARK: - smart playlists

struct SmartRule: Codable, Hashable, Identifiable {
    var id = UUID().uuidString
    var field = "artist"      // title artist album plays year minutes addedDays playedDays liked
    var op = "contains"       // contains is not  > < =  yes no
    var value = ""
    static let fields: [(String, String)] = [("title", "Title"), ("artist", "Artist"), ("album", "Album"), ("plays", "Plays"), ("year", "Year"), ("minutes", "Length (minutes)"), ("addedDays", "Added (days ago)"), ("playedDays", "Last played (days ago)"), ("liked", "Favorite")]
    var isText: Bool { ["title", "artist", "album"].contains(field) }
    var isBool: Bool { field == "liked" }
}

struct SmartPlaylist: Codable, Hashable, Identifiable {
    var id = UUID().uuidString
    var name = "Smart Playlist"
    var matchAll = true
    var rules: [SmartRule] = [SmartRule()]
    var limit = 0                 // 0 = no limit
    var sort = "title"            // title plays played added random

    static let builtIn: [SmartPlaylist] = [
        SmartPlaylist(id: "builtin:most", name: "Most Played", matchAll: true, rules: [SmartRule(field: "plays", op: ">", value: "0")], limit: 100, sort: "plays"),
        SmartPlaylist(id: "builtin:recent", name: "Recently Played", matchAll: true, rules: [SmartRule(field: "playedDays", op: "<", value: "60")], limit: 100, sort: "played"),
        SmartPlaylist(id: "builtin:never", name: "Never Played", matchAll: true, rules: [SmartRule(field: "plays", op: "=", value: "0")], limit: 0, sort: "added"),
    ]
    var isBuiltIn: Bool { id.hasPrefix("builtin:") }
}

extension Library {
    func songs(in sp: SmartPlaylist) -> [Song] {
        let now = Date().timeIntervalSince1970
        func test(_ s: Song, _ r: SmartRule) -> Bool {
            if r.isBool { let f = favorites.contains(s.id); return r.op == "yes" ? f : !f }
            if r.isText {
                let v = r.value.lowercased()
                let t = (r.field == "title" ? s.title : r.field == "artist" ? s.artist : s.album).lowercased()
                switch r.op { case "is": return t == v; case "not": return !t.contains(v); default: return v.isEmpty || t.contains(v) }
            }
            let x: Double
            switch r.field {
            case "plays": x = Double(s.plays ?? 0)
            case "year": x = Double(Int(s.year) ?? 0)
            case "minutes": x = s.duration / 60
            case "addedDays": x = (now - s.added) / 86400
            default: x = s.lastPlayed.map { (now - $0) / 86400 } ?? 1e9
            }
            let v = Double(r.value) ?? 0
            switch r.op { case ">": return x > v; case "<": return x < v; default: return abs(x - v) < 0.5 }
        }
        var out = songs.filter { s in sp.rules.isEmpty ? true : (sp.matchAll ? sp.rules.allSatisfy { test(s, $0) } : sp.rules.contains { test(s, $0) }) }
        switch sp.sort {
        case "plays": out.sort { ($0.plays ?? 0) > ($1.plays ?? 0) }
        case "played": out.sort { ($0.lastPlayed ?? 0) > ($1.lastPlayed ?? 0) }
        case "added": out.sort { $0.added > $1.added }
        case "random": out.shuffle()
        default: out.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        return sp.limit > 0 ? Array(out.prefix(sp.limit)) : out
    }
    func smartPlaylist(_ id: String) -> SmartPlaylist? { (SmartPlaylist.builtIn + smart).first { $0.id == id } }
}

struct SmartEditor: View {
    @State var sp: SmartPlaylist
    var isNew: Bool
    @EnvironmentObject var lib: Library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Smart Playlist" : "Edit Smart Playlist").font(.title2.weight(.bold))
            TextField("Name", text: $sp.name)
            Picker("Match", selection: $sp.matchAll) { Text("all of these rules").tag(true); Text("any of these rules").tag(false) }.pickerStyle(.segmented).labelsHidden()
            ForEach($sp.rules) { $r in
                HStack {
                    Picker("", selection: $r.field) { ForEach(SmartRule.fields, id: \.0) { Text($0.1).tag($0.0) } }.labelsHidden().frame(width: 160)
                        .onChange(of: r.field) { _ in r.op = r.isBool ? "yes" : (r.isText ? "contains" : ">") }
                    if r.isBool {
                        Picker("", selection: $r.op) { Text("is a favorite").tag("yes"); Text("is not").tag("no") }.labelsHidden().frame(width: 120)
                    } else {
                        Picker("", selection: $r.op) {
                            if r.isText { Text("contains").tag("contains"); Text("is").tag("is"); Text("doesn't contain").tag("not") }
                            else { Text("more than").tag(">"); Text("less than").tag("<"); Text("exactly").tag("=") }
                        }.labelsHidden().frame(width: 130)
                        TextField("", text: $r.value)
                    }
                    Button { sp.rules.removeAll { $0.id == r.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                }
            }
            Button { sp.rules.append(SmartRule()) } label: { Label("Add a rule", systemImage: "plus.circle") }.buttonStyle(.plain)
            HStack {
                Picker("Sort by", selection: $sp.sort) { Text("Title").tag("title"); Text("Most played").tag("plays"); Text("Last played").tag("played"); Text("Newest").tag("added"); Text("Random").tag("random") }.frame(width: 220)
                Stepper(sp.limit == 0 ? "No limit" : "Limit to \(sp.limit) songs", value: $sp.limit, in: 0...1000, step: 25)
            }
            Text("\(lib.songs(in: sp).count) songs match right now").font(.callout).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Save") { lib.saveSmart(sp); dismiss() }.keyboardShortcut(.defaultAction).disabled(sp.name.trimmingCharacters(in: .whitespaces).isEmpty) }
        }
        .padding(22).frame(width: 540)
    }
}

// MARK: - playlists: M3U in and out, Apple Music import

extension Library {
    func exportM3U(_ p: Playlist) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "\(p.name).m3u"; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        var text = "#EXTM3U\n"
        for s in songs(in: p) { text += "#EXTINF:\(Int(s.duration)),\(s.shownArtist) - \(s.title)\n\(s.path)\n" }
        try? text.write(to: dest, atomically: true, encoding: .utf8)
        flash("Saved \(p.name).m3u")
    }

    func importM3U() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "m3u") ?? .plainText, UTType(filenameExtension: "m3u8") ?? .plainText]
        guard panel.runModal() == .OK, let u = panel.url, let text = try? String(contentsOf: u, encoding: .utf8) else { return }
        let dir = u.deletingLastPathComponent()
        var ids: [String] = []
        let byPath = Dictionary(songs.map { ($0.path, $0.id) }, uniquingKeysWith: { a, _ in a })
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let l = String(line).trimmingCharacters(in: .whitespaces)
            let path = l.hasPrefix("/") ? l : dir.appendingPathComponent(l).standardized.path
            if let id = byPath[path] { ids.append(id) }
        }
        newPlaylist(u.deletingPathExtension().lastPathComponent, with: ids)
        flash("Imported \(ids.count) songs")
    }

    func duplicate(_ p: Playlist) { playlists.append(Playlist(id: UUID().uuidString, name: p.name + " copy", songIDs: p.songIDs)); save() }

    /// Music > File > Library > Export Library… (the XML file): files, play counts, favorites and playlists
    func importAppleMusic() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.xml, .propertyList]; panel.message = "Choose the Library.xml you exported from the Music app"
        guard panel.runModal() == .OK, let u = panel.url else { return }
        Task {
            status = "Reading the Music library…"
            guard let data = try? Data(contentsOf: u), let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  let tracks = plist["Tracks"] as? [String: [String: Any]] else { flash("That doesn't look like a Music library export"); return }
            var files: [URL] = []
            var trackPath: [Int: String] = [:]
            for (k, t) in tracks {
                guard let loc = t["Location"] as? String, let url = URL(string: loc), url.isFileURL, let id = Int(k) else { continue }
                if FileManager.default.fileExists(atPath: url.path), Disk.playable.contains(url.pathExtension.lowercased()) { files.append(url); trackPath[id] = url.path }
            }
            await importAsync(files, remember: false)
            for (k, t) in tracks {
                guard let id = Int(k), let path = trackPath[id], let i = songs.firstIndex(where: { $0.path == path }) else { continue }
                if let c = t["Play Count"] as? Int, c > (songs[i].plays ?? 0) { songs[i].plays = c }
                if (t["Loved"] as? Bool) == true || (t["Favorite"] as? Bool) == true { favorites.insert(songs[i].id) }
            }
            let byPath = Dictionary(songs.map { ($0.path, $0.id) }, uniquingKeysWith: { a, _ in a })
            var made = 0
            for pl in plist["Playlists"] as? [[String: Any]] ?? [] {
                if pl["Master"] != nil || pl["Distinguished Kind"] != nil || pl["Smart Info"] != nil || pl["Folder"] != nil { continue }
                let items = (pl["Playlist Items"] as? [[String: Any]] ?? []).compactMap { $0["Track ID"] as? Int }
                let ids = items.compactMap { trackPath[$0] }.compactMap { byPath[$0] }
                if let name = pl["Name"] as? String, !ids.isEmpty, !playlists.contains(where: { $0.name == name }) { newPlaylist(name, with: ids); made += 1 }
            }
            rebuildNow(); save()
            flash("Brought over \(files.count) songs and \(made) playlists from Music")
        }
    }

    // MARK: finding covers

    func findMissingCovers() {
        Task {
            let missing = Dictionary(grouping: songs.filter { $0.cover.isEmpty }, by: { $0.albumKey })
            guard !missing.isEmpty else { flash("Every song already has a cover"); return }
            var done = 0
            for (i, (_, group)) in missing.enumerated() {
                let f = group[0]
                status = "Looking for covers… \(i + 1) of \(missing.count)"
                let term = f.album.isEmpty ? "\(f.title) \(f.artist)" : "\(f.album) \(f.artistKey)"
                var found = await ITunes.album(term)
                if found == nil && !f.album.isEmpty { found = await ITunes.songs(term).first?.art }
                if let u = found, let d = await ITunes.image(u) {
                    let name = Disk.saveCover(d)
                    for s in group { if let j = songs.firstIndex(where: { $0.id == s.id }) { songs[j].cover = name } }
                    done += 1
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            rebuildNow(); save()
            flash("Found covers for \(done) of \(missing.count) albums")
        }
    }
}

// MARK: - duplicates

struct DuplicatesView: View {
    @EnvironmentObject var lib: Library
    private var groups: [[Song]] {
        Dictionary(grouping: lib.songs, by: { $0.title.lowercased() + "|" + primaryArtist($0.artist).lowercased() }).values.filter { $0.count > 1 }
            .sorted { $0[0].title.localizedCaseInsensitiveCompare($1[0].title) == .orderedAscending }
    }
    var body: some View {
        let g = groups
        if g.isEmpty {
            VStack(spacing: 10) { Image(systemName: "checkmark.circle").font(.system(size: 46)).foregroundStyle(.green); Text("No duplicates").font(.title3.weight(.semibold)); Text("No two songs share a title and artist.").foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(g, id: \.first?.id) { group in
                    Section("\(group[0].title) · \(group[0].shownArtist)") {
                        ForEach(group) { s in
                            HStack {
                                VStack(alignment: .leading) { Text(s.url.lastPathComponent); Text("\(s.path)  ·  \(fmtTime(s.duration))  ·  \(s.ext.uppercased())").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                                Spacer()
                                Button("Remove from Library") { lib.remove([s.id]) }
                                Button("Move File to Trash", role: .destructive) { NSWorkspace.shared.recycle([s.url]) { _, _ in Task { @MainActor in lib.remove([s.id]) } } }
                            }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
    }
}

// MARK: - watching the music folders

final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private var paths: [String] = []
    var onChange: (() -> Void)?

    func watch(_ p: [String]) {
        guard p != paths else { return }
        paths = p
        if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s); stream = nil }
        guard !p.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info = info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onChange?()
        }
        guard let s = FSEventStreamCreate(nil, cb, &ctx, p as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 3.0,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)) else { return }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
        stream = s
    }
}
