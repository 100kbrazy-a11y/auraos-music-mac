import Foundation
import SwiftUI

struct LyricLine: Identifiable, Hashable {
    let id: Int
    let time: Double
    let text: String
}

/// synced lyrics: a .lrc file next to the song first, then LRCLIB (free, no sign-in)
@MainActor
final class LyricsStore: ObservableObject {
    @Published var lines: [LyricLine] = []
    @Published var plain: String = ""
    @Published var loading = false
    @Published var synced = false

    private struct Cached: Codable { var synced: String; var plain: String }

    func load(for s: Song) async {
        lines = []; plain = ""; synced = false; loading = true
        defer { loading = false }
        // 1. an .lrc beside the song
        let lrc = s.url.deletingPathExtension().appendingPathExtension("lrc")
        if let t = try? String(contentsOf: lrc, encoding: .utf8), let parsed = Self.parse(t), !parsed.isEmpty { lines = parsed; synced = true; return }
        // 2. what was found before
        let cacheURL = Disk.dir.appendingPathComponent("lyrics/\(s.id).json")
        if let d = try? Data(contentsOf: cacheURL), let c = try? JSONDecoder().decode(Cached.self, from: d) { apply(c); return }
        // 3. LRCLIB
        guard let c = await Self.fetch(s) else { return }
        if s.id == Player.shared.current?.id {
            apply(c)
            if let d = try? JSONEncoder().encode(c) { try? d.write(to: cacheURL) }
        }
    }

    private func apply(_ c: Cached) {
        if let p = Self.parse(c.synced), !p.isEmpty { lines = p; synced = true }
        plain = c.plain
    }

    private static func fetch(_ s: Song) async -> Cached? {
        func get(_ path: String, _ items: [URLQueryItem]) async -> [String: Any]? {
            var comp = URLComponents(string: "https://lrclib.net/api/\(path)")!
            comp.queryItems = items
            guard let u = comp.url else { return nil }
            var req = URLRequest(url: u); req.setValue("Strata Music for Mac", forHTTPHeaderField: "User-Agent"); req.timeoutInterval = 12
            guard let (d, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            if let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return j }
            if let a = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] { return a.first(where: { ($0["syncedLyrics"] as? String)?.isEmpty == false }) ?? a.first }
            return nil
        }
        var items = [URLQueryItem(name: "track_name", value: s.title), URLQueryItem(name: "artist_name", value: primaryArtist(s.artist))]
        if !s.album.isEmpty { items.append(URLQueryItem(name: "album_name", value: s.album)) }
        items.append(URLQueryItem(name: "duration", value: String(Int(s.duration.rounded()))))
        var j = await get("get", items)
        if j == nil { j = await get("search", [URLQueryItem(name: "q", value: "\(s.title) \(primaryArtist(s.artist))")]) }
        guard let r = j else { return nil }
        let synced = (r["syncedLyrics"] as? String) ?? ""
        let plain = (r["plainLyrics"] as? String) ?? ""
        if synced.isEmpty && plain.isEmpty { return nil }
        return Cached(synced: synced, plain: plain)
    }

    /// "[01:23.45] words" lines (several stamps per line are fine)
    static func parse(_ text: String) -> [LyricLine]? {
        var out: [(Double, String)] = []
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            var line = Substring(raw)
            var stamps: [Double] = []
            while line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                let tag = line[line.index(after: line.startIndex)..<close]
                let parts = tag.split(separator: ":")
                if parts.count == 2, let m = Double(parts[0]), let s = Double(parts[1]) { stamps.append(m * 60 + s) }
                line = line[line.index(after: close)...]
            }
            let words = line.trimmingCharacters(in: .whitespaces)
            for t in stamps { out.append((t, words)) }
        }
        if out.isEmpty { return nil }
        out.sort { $0.0 < $1.0 }
        return out.enumerated().map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }
}
