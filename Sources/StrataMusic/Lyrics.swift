import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LyricWord: Hashable {
    let text: String       // includes the space after it
    let start: Double
    var end: Double? = nil   // when it stops being sung, if the file says (a time with no word after it): after a pause, nothing stays lit
}

struct LyricLine: Identifiable, Hashable {
    let id: Int
    let time: Double
    let text: String
    var words: [LyricWord] = []
    var end: Double = 0
    var tagged = false        // the file gave a time for each word (rather than us spreading the words over the line)
    var sungEnd: Double = 0   // when the last word has been sung (it can be after the next line has started, for ad-libs)
}

/// which lines are lit: normally one, two when an ad-lib is sung over the end of a line; or a quiet stretch (shown as dots) instead
struct LyricFocus: Equatable {
    var main = -1             // the line being sung (the older one when two overlap)
    var extra = -1            // a second line sung at the same time
    var gap = -1              // the quiet stretch we are in, named by the line that follows it (the line count = after the last line)
    var target: Double { gap >= 0 ? Double(gap) - 0.5 : Double(max(main, 0)) }
    var scrollID: Int { gap >= 0 ? 1000 + gap : max(main, 0) }
    func lit(_ id: Int) -> Bool { id == main || id == extra }
}

/// hides the worst words when the "censor" option is on
enum LyricsFilter {
    private static let bad = ["fuck", "shit", "bitch", "asshole", "dick", "pussy", "cunt", "bastard", "whore", "slut", "cock", "nigg", "fag"]
    static var on: Bool { UserDefaults.standard.bool(forKey: "censorLyrics") }

    static func clean(_ s: String) -> String {
        guard on else { return s }
        var out = s
        for w in bad {
            guard let re = try? NSRegularExpression(pattern: "\\b\(w)\\w*", options: .caseInsensitive) else { continue }
            let ns = out as NSString
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
                let word = ns.substring(with: m.range)
                out = (out as NSString).replacingCharacters(in: m.range, with: String(word.prefix(1)) + String(repeating: "*", count: max(0, word.count - 1)))
            }
        }
        return out
    }

    /// the same words in Latin letters (for Japanese, Korean, Russian, Arabic and so on), or nil when there's nothing to change
    static func romanize(_ s: String) -> String? {
        guard s.unicodeScalars.contains(where: { $0.value > 0x24F }) else { return nil }
        guard let r = s.applyingTransform(.toLatin, reverse: false), r != s else { return nil }
        let t = r.applyingTransform(.stripDiacritics, reverse: false) ?? r
        return t.trimmingCharacters(in: .whitespaces).isEmpty ? nil : t
    }
}

/// synced lyrics: your own file first, then a .lrc beside the song, then LRCLIB (free, no sign-in)
@MainActor
final class LyricsStore: ObservableObject {
    static let shared = LyricsStore()

    @Published var lines: [LyricLine] = []
    @Published var plain: String = ""
    @Published var loading = false
    @Published var synced = false
    @Published var offset = 0.0                 // seconds; + shows each line later
    @Published var markedNone = false
    @Published var hasOwnFile = false
    @Published var wordSynced = false           // the words carry times found by listening to the song (see Aligner)
    @Published var translated: [Int: String] = [:]
    @Published var translating = false
    private(set) var loadedID = ""

    private struct Cached: Codable { var synced: String; var plain: String }
    private var offsets: [String: Double] = [:]
    private var noneIDs: Set<String> = []
    private var dir: URL { Disk.dir.appendingPathComponent("lyrics", isDirectory: true) }

    init() {
        if let d = try? Data(contentsOf: dir.appendingPathComponent("offsets.json")), let o = try? JSONDecoder().decode([String: Double].self, from: d) { offsets = o }
        if let d = try? Data(contentsOf: dir.appendingPathComponent("none.json")), let n = try? JSONDecoder().decode([String].self, from: d) { noneIDs = Set(n) }
    }

    /// loads for [s] unless that's already what we have
    func ensure(_ s: Song) async { if loadedID != s.id { await load(for: s) } }

    func load(for s: Song) async {
        await loadSource(s)
        guard loadedID == s.id else { return }
        mergeAligned(id: s.id)
        WordSync.shared.consider(s)
    }

    func alignedURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).aligned.lrc") }

    /// swaps in the word times found by listening to the song, when they belong to these very lyrics
    @discardableResult
    func mergeAligned(id: String) -> Bool {
        wordSynced = false
        guard synced, let t = try? String(contentsOf: alignedURL(id), encoding: .utf8), let p = Self.parse(t), p.count == lines.count else { return false }
        for (a, b) in zip(p, lines) where a.text != b.text { return false }
        lines = p
        wordSynced = true
        return true
    }

    func clearAligned(_ song: Song) async {
        try? FileManager.default.removeItem(at: alignedURL(song.id))
        await load(for: song)
    }

    private func loadSource(_ s: Song) async {
        loadedID = s.id
        wordSynced = false
        lines = []; plain = ""; synced = false; translated = [:]
        offset = offsets[s.id] ?? 0
        markedNone = noneIDs.contains(s.id)
        let own = dir.appendingPathComponent("\(s.id).lrc")
        hasOwnFile = FileManager.default.fileExists(atPath: own.path)
        if markedNone { loading = false; return }
        loading = true
        defer { if loadedID == s.id { loading = false } }
        // 0. a file you imported
        if let t = try? String(contentsOf: own, encoding: .utf8), let parsed = Self.parse(t), !parsed.isEmpty { lines = parsed; synced = true; return }
        // 1. an .lrc beside the song
        let lrc = s.url.deletingPathExtension().appendingPathExtension("lrc")
        if let t = try? String(contentsOf: lrc, encoding: .utf8), let parsed = Self.parse(t), !parsed.isEmpty { lines = parsed; synced = true; return }
        // 2. what was found before
        let cacheURL = dir.appendingPathComponent("\(s.id).json")
        if let d = try? Data(contentsOf: cacheURL), let c = try? JSONDecoder().decode(Cached.self, from: d) { apply(c); return }
        // 3. LRCLIB
        guard let c = await Self.fetch(s), loadedID == s.id else { return }
        apply(c)
        if let d = try? JSONEncoder().encode(c) { try? d.write(to: cacheURL) }
    }

    private func apply(_ c: Cached) {
        if let p = Self.parse(c.synced), !p.isEmpty { lines = p; synced = true }
        plain = c.plain
    }

    // MARK: things you can change about a song's lyrics

    func nudge(_ by: Double, song: Song) { setOffset(((offset + by) * 100).rounded() / 100, song: song) }
    func setOffset(_ v: Double, song: Song) {
        offset = v
        if v == 0 { offsets[song.id] = nil } else { offsets[song.id] = v }
        if let d = try? JSONEncoder().encode(offsets) { try? d.write(to: dir.appendingPathComponent("offsets.json")) }
    }

    func toggleNone(_ song: Song) async {
        if noneIDs.contains(song.id) { noneIDs.remove(song.id) } else { noneIDs.insert(song.id) }
        if let d = try? JSONEncoder().encode(Array(noneIDs)) { try? d.write(to: dir.appendingPathComponent("none.json")) }
        await load(for: song)
    }

    /// pick a .lrc (or a plain text file of lyrics) for this song
    func importFile(for song: Song) async {
        let p = NSOpenPanel()
        p.message = "Choose a lyrics file (.lrc, or a plain .txt)"
        p.allowedContentTypes = [UTType(filenameExtension: "lrc") ?? .plainText, .plainText]
        guard p.runModal() == .OK, let u = p.url, let text = try? String(contentsOf: u, encoding: .utf8) else { return }
        if let parsed = Self.parse(text), !parsed.isEmpty {
            try? text.write(to: dir.appendingPathComponent("\(song.id).lrc"), atomically: true, encoding: .utf8)
        } else {
            let c = Cached(synced: "", plain: text)
            if let d = try? JSONEncoder().encode(c) { try? d.write(to: dir.appendingPathComponent("\(song.id).json")) }
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(song.id).lrc"))
        }
        if noneIDs.contains(song.id) { noneIDs.remove(song.id); if let d = try? JSONEncoder().encode(Array(noneIDs)) { try? d.write(to: dir.appendingPathComponent("none.json")) } }
        try? FileManager.default.removeItem(at: alignedURL(song.id))
        await load(for: song)
    }

    func removeOwnFile(for song: Song) async {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(song.id).lrc"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(song.id).json"))
        try? FileManager.default.removeItem(at: alignedURL(song.id))
        await load(for: song)
    }

    // MARK: finding the current line

    func index(at position: Double) -> Int {
        var lo = 0, hi = lines.count - 1, ans = -1
        let t = position + 0.2 - offset
        while lo <= hi { let mid = (lo + hi) / 2; if lines[mid].time <= t { ans = mid; lo = mid + 1 } else { hi = mid - 1 } }
        return ans
    }

    // MARK: the web

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

    // MARK: reading .lrc

    private static let wordTag = try! NSRegularExpression(pattern: "<(\\d+):(\\d+(?:\\.\\d+)?)>")

    /// "[01:23.45] words", and the enhanced kind with <01:23.45> before each word (several stamps per line are fine)
    static func parse(_ text: String) -> [LyricLine]? {
        var out: [(Double, String, [LyricWord])] = []
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            var line = Substring(raw)
            var stamps: [Double] = []
            while line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                let tag = line[line.index(after: line.startIndex)..<close]
                let parts = tag.split(separator: ":")
                if parts.count == 2, let m = Double(parts[0]), let s = Double(parts[1]) { stamps.append(m * 60 + s) }
                line = line[line.index(after: close)...]
            }
            let (words, tagged) = split(String(line))
            for t in stamps { out.append((t, words, tagged)) }
        }
        if out.isEmpty { return nil }
        out.sort { $0.0 < $1.0 }
        func adlib(_ s: String) -> Bool { let t = s.trimmingCharacters(in: .whitespaces); return t.count > 2 && t.hasPrefix("(") && t.hasSuffix(")") }
        var result: [LyricLine] = []
        for (i, o) in out.enumerated() {
            let next = i + 1 < out.count ? out[i + 1].0 : o.0 + 5
            // a line is sung right through the (bracketed) ad-libs that come after it, not cut off where they start
            var limit = next
            if !adlib(o.1) {
                var k = i + 1
                while k < out.count, adlib(out[k].1) { k += 1 }
                limit = k < out.count ? out[k].0 : max(next, out[out.count - 1].0 + 3)
            }
            var l = LyricLine(id: i, time: o.0, text: o.1)
            l.tagged = !o.2.isEmpty
            l.end = next
            if o.2.isEmpty {
                let e = estimateSpan(o.1, from: o.0, to: limit)
                l.words = e.words
                l.sungEnd = e.end
            } else {
                l.words = o.2
                let last = o.2[o.2.count - 1].start
                if let e = o.2[o.2.count - 1].end, e > last { l.sungEnd = e }
                else { l.sungEnd = last + min(1.2, max(0.45, next - last)) }
            }
            result.append(l)
        }
        return result
    }

    /// the line without its word tags, plus the words those tags describe
    private static func split(_ body: String) -> (String, [LyricWord]) {
        let ns = body as NSString
        let ms = wordTag.matches(in: body, range: NSRange(location: 0, length: ns.length))
        if ms.isEmpty { return (body.trimmingCharacters(in: .whitespaces), []) }
        var plain = ns.substring(to: ms[0].range.location)
        var words: [LyricWord] = []
        for (i, m) in ms.enumerated() {
            let t = (Double(ns.substring(with: m.range(at: 1))) ?? 0) * 60 + (Double(ns.substring(with: m.range(at: 2))) ?? 0)
            let end = i + 1 < ms.count ? ms[i + 1].range.location : ns.length
            let chunk = ns.substring(with: NSRange(location: m.range.location + m.range.length, length: end - (m.range.location + m.range.length)))
            if !chunk.isEmpty { words.append(LyricWord(text: chunk, start: t)); plain += chunk }
            else if let last = words.last, t > last.start, last.end == nil { words[words.count - 1].end = t }
        }
        return (plain.trimmingCharacters(in: .whitespaces), words)
    }

    /// how many beats a word takes to sing: syllables for letters we can count, one per character for scripts without spaces
    private static func weight(_ w: String) -> Double {
        let t = w.trimmingCharacters(in: .whitespacesAndNewlines)
        let letters = t.filter { $0.isLetter }
        guard !letters.isEmpty else { return 0.4 }
        if t.unicodeScalars.contains(where: { $0.value > 0x24F }) { return Double(letters.count) }
        let vowels = Set("aeiouyáàâäãåéèêëíìîïóòôöõúùûüœæ")
        var groups = 0, inGroup = false
        for ch in letters.lowercased() { if vowels.contains(ch) { if !inGroup { groups += 1; inGroup = true } } else { inGroup = false } }
        let lower = letters.lowercased()
        if groups > 1, lower.hasSuffix("e"), !lower.hasSuffix("le") { groups -= 1 }      // a silent final e
        if lower.hasSuffix("ed") && groups > 1 && !(lower.hasSuffix("ted") || lower.hasSuffix("ded")) { groups -= 1 }
        var w = Double(max(groups, 1))
        if t.hasSuffix(",") || t.hasSuffix(";") { w += 0.5 }
        if t.hasSuffix(".") || t.hasSuffix("!") || t.hasSuffix("?") || t.hasSuffix("…") { w += 0.9 }
        return w
    }

    /// no word timings in the file: the words are spread over the part of the line that is actually sung. A line that runs into the next one
    /// fills the gap (less a breath); a line followed by a long pause is sung at a natural pace and then stops.
    static func estimate(_ text: String, from a: Double, to b: Double) -> [LyricWord] { estimateSpan(text, from: a, to: b).words }

    static func estimateSpan(_ text: String, from a: Double, to b: Double) -> (words: [LyricWord], end: Double) {
        guard !text.isEmpty else { return ([], a) }
        var pieces: [String]
        if text.contains(" ") {
            let ws = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            pieces = ws.enumerated().map { $0.offset < ws.count - 1 ? $0.element + " " : $0.element }
        } else {
            pieces = text.map { String($0) }
        }
        var weights = pieces.map { weight($0) }
        if let last = weights.indices.last { weights[last] += 0.6 }          // the last note of a line is usually held
        let total = weights.reduce(0, +)
        let gap = max(b - a, 0.5)
        let natural = total * 0.26 + 0.25
        let span = gap <= natural * 1.7 ? max(gap - 0.18, gap * 0.8) : min(gap * 0.9, natural * 1.3)
        var acc = 0.0
        var out: [LyricWord] = []
        for (i, p) in pieces.enumerated() {
            out.append(LyricWord(text: p, start: a + span * acc / total))
            acc += weights[i]
        }
        return (out, a + span)
    }

    // MARK: which lines are lit, and the quiet stretches

    /// the stretches with nothing sung that are long enough to show dots for: key = the line that follows (the line count = after the last line)
    func gaps(duration: Double) -> [Int: ClosedRange<Double>] {
        let key = "\(loadedID)|\(lines.count)|\(Int(duration))|\(wordSynced)|\(Int((lines.last?.sungEnd ?? 0) * 10))"
        if let c = gapCache, c.key == key { return c.value }
        let g = computeGaps(duration: duration)
        gapCache = (key, g)
        return g
    }
    private var gapCache: (key: String, value: [Int: ClosedRange<Double>])?

    private func computeGaps(duration: Double) -> [Int: ClosedRange<Double>] {
        var out: [Int: ClosedRange<Double>] = [:]
        guard let first = lines.first, let last = lines.last else { return out }
        if first.time >= 4, !first.text.isEmpty { out[0] = 0...first.time }
        if lines.count > 1 {
            for i in 0..<(lines.count - 1) where !lines[i].text.isEmpty && !lines[i + 1].text.isEmpty {
                let a = lines[i].sungEnd, b = lines[i + 1].time
                if b - a >= 7 { out[i + 1] = (a + 0.4)...b }
            }
        }
        if !last.text.isEmpty, duration - last.sungEnd >= 8 { out[lines.count] = (last.sungEnd + 0.4)...duration }
        return out
    }

    func focus(at position: Double, duration: Double) -> LyricFocus {
        var f = LyricFocus()
        guard !lines.isEmpty else { return f }
        let t = position + 0.2 - offset
        let gs = gaps(duration: duration)
        let i = index(at: position)
        if i < 0 { if gs[0] != nil { f.gap = 0 }; return f }
        // an earlier line that is still being sung while this one has started (an ad-lib over its end)
        var j = i - 1
        while j >= 0 && j >= i - 2 {
            if lines[j].sungEnd > t && lines[j].sungEnd > lines[i].time + 0.3 { f.main = j; f.extra = i; return f }
            j -= 1
        }
        if t > lines[i].sungEnd, let g = gs[i + 1], g.contains(t) { f.gap = i + 1; return f }
        f.main = i
        return f
    }
}
