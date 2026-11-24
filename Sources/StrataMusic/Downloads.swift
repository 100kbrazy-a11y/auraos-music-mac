import Foundation
import AVFoundation
import ImageIO
import AppKit
import SwiftUI

struct DlItem: Identifiable, Equatable {
    var track: Track
    var status = "Waiting"
    var frac = 0.0
    var speed = 0.0            // bytes per second
    var bytes: Int64 = 0
    var size: Int64 = 0
    var done = false
    var failed = false
    var playWhenReady = false
    var id: String { track.id }
}

/// one request at a time (with a short breather after each) for "ask YouTube for the audio address": it is what YouTube is touchiest about
private actor Gate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func enter() async { if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true } }
    func leave() { if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() } }
}

/// remembers the last speed sample (the download pieces report from several places at once)
private final class SpeedMeter: @unchecked Sendable {
    private var lastB: Int64 = 0, lastT = Date(), ema = 0.0
    func tick(_ got: Int64) -> Double {
        let now = Date(); let dt = now.timeIntervalSince(lastT)
        if dt >= 0.5 { let inst = Double(got - lastB) / dt; ema = ema == 0 ? inst : ema * 0.6 + inst * 0.4; lastB = got; lastT = now }
        return ema
    }
}

/// a file being filled from several places at once
private actor FileSink {
    private let fh: FileHandle
    private(set) var got: Int64 = 0
    init(_ fh: FileHandle) { self.fh = fh }
    func write(_ d: Data, at off: Int64) throws { try fh.seek(toOffset: UInt64(off)); try fh.write(contentsOf: d); got += Int64(d.count) }
    func undo(_ n: Int64) { got -= n }
}

/// The download queue. The hidden browser is only asked for the audio *address*; the file itself is fetched natively, in pieces,
/// several at a time (YouTube hands out audio slowly on one long connection and quickly on several short ones).
@MainActor
final class Downloads: ObservableObject {
    static let shared = Downloads()
    @Published private(set) var items: [DlItem] = []
    weak var lib: Library?

    private var tasks: [String: Task<Void, Never>] = [:]
    private var failStreak = 0
    private let gate = Gate()
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false; c.httpCookieAcceptPolicy = .never; c.timeoutIntervalForRequest = 30
        c.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: c)
    }()

    var active: Int { items.filter { !$0.done && !$0.failed }.count }
    var finished: Int { items.filter { $0.done }.count }
    var parallel: Int { max(1, min(4, UserDefaults.standard.object(forKey: "dlParallel") as? Int ?? 2)) }

    nonisolated static var folder: URL {
        get {
            if let p = UserDefaults.standard.string(forKey: "dlFolder"), !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true) }
            return FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0].appendingPathComponent("Strata Music", isDirectory: true)
        }
        set { UserDefaults.standard.set(newValue.path, forKey: "dlFolder") }
    }

    // MARK: the queue

    func add(_ list: [Track], play: Bool = false) {
        for t in list {
            if let i = items.firstIndex(where: { $0.id == t.id }) {
                if items[i].failed { items[i] = DlItem(track: t, playWhenReady: play) }
                else if play { items[i].playWhenReady = true }
                continue
            }
            items.append(DlItem(track: t, playWhenReady: play))
        }
        pump()
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel(); tasks[id] = nil
        items.removeAll { $0.id == id && !$0.done }
        pump()
    }

    func retry(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].failed else { return }
        items[i].failed = false; items[i].status = "Waiting"; items[i].frac = 0
        pump()
    }

    func clearFinished() { items.removeAll { $0.done || $0.failed } }

    func cancelAll() { for (_, t) in tasks { t.cancel() }; tasks = [:]; items.removeAll { !$0.done }; }

    private func pump() {
        while tasks.count < parallel, let next = items.first(where: { !$0.done && !$0.failed && tasks[$0.id] == nil }) {
            let id = next.id
            tasks[id] = Task { [weak self] in
                await self?.process(id)
                await MainActor.run { self?.tasks[id] = nil; self?.pump() }
            }
        }
    }

    private func upd(_ id: String, _ f: (inout DlItem) -> Void) {
        if let i = items.firstIndex(where: { $0.id == id }) { f(&items[i]) }
    }

    // MARK: one song

    private func process(_ id: String) async {
        guard let item = items.first(where: { $0.id == id }), let lib = lib else { return }
        let t = item.track
        if let s = lib.songs.first(where: { $0.yt == t.id }) {
            upd(id) { $0.status = "Already in your library"; $0.frac = 1; $0.done = true }
            if item.playWhenReady { Player.shared.play(s, in: [s]) }
            return
        }
        let coverTask = Task.detached { await Self.sharpCover(t.thumb) }
        var last = ""
        for attempt in 1...4 {
            if Task.isCancelled { coverTask.cancel(); return }
            do {
                upd(id) { $0.status = attempt == 1 ? "Asking YouTube…" : "Trying again (\(attempt) of 4)…"; $0.frac = 0; $0.speed = 0; $0.bytes = 0 }
                await gate.enter()
                let src: YtEngine.Source
                do { src = try await YtEngine.shared.source(for: id) } catch { try? await Task.sleep(nanoseconds: 250_000_000); await gate.leave(); throw error }
                try? await Task.sleep(nanoseconds: 250_000_000); await gate.leave()

                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("strata-yt-\(id).\(src.ext)")
                defer { try? FileManager.default.removeItem(at: tmp) }
                upd(id) { $0.status = "Downloading…" }
                let meter = SpeedMeter()
                try await fetch(src, to: tmp) { [weak self] got, total in
                    Task { @MainActor in
                        let speed = meter.tick(got)
                        self?.upd(id) { $0.bytes = got; $0.size = total; $0.frac = total > 0 ? min(1, Double(got) / Double(total)) : 0; $0.speed = speed }
                    }
                }
                upd(id) { $0.status = "Adding to your library…"; $0.speed = 0 }
                let cover = await coverTask.value
                var full = t
                if full.title.isEmpty { full.title = src.title }
                if full.artist.isEmpty { full.artist = src.artist }
                let dest = Self.destination(for: full, ext: "m4a")
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                do { try await Self.tag(tmp, to: dest, full, cover) }
                catch { try? FileManager.default.removeItem(at: dest); try FileManager.default.copyItem(at: tmp, to: dest) }   // untagged is better than nothing
                let folder = Self.folder.path
                if !lib.folders.contains(folder) { lib.folders.append(folder) }
                guard let song = await lib.addDownloaded(dest, track: full, cover: cover, fallbackDuration: Double(src.duration)) else { throw YtError("The downloaded file couldn't be read") }
                upd(id) { $0.status = "Added"; $0.frac = 1; $0.done = true; $0.speed = 0 }
                failStreak = 0
                if item.playWhenReady || items.first(where: { $0.id == id })?.playWhenReady == true { Player.shared.play(song, in: [song]) }
                return
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                last = (error as? YtError)?.errorDescription ?? error.localizedDescription
            }
            failStreak += 1
            if failStreak >= 3 { failStreak = 0; YtEngine.shared.reset() }
            try? await Task.sleep(nanoseconds: UInt64(1_500_000_000 * attempt))
        }
        coverTask.cancel()
        upd(id) { $0.status = last.replacingOccurrences(of: #"https://\S+"#, with: "(address)", options: .regularExpression); $0.failed = true; $0.speed = 0 }
    }

    // MARK: the file itself

    private func request(_ src: YtEngine.Source, range: (Int64, Int64)?) -> URLRequest? {
        var u = src.url
        if let r = range { u += "&range=\(r.0)-\(r.1)" }
        guard let url = URL(string: u) else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 30
        if !src.ua.isEmpty { req.setValue(src.ua, forHTTPHeaderField: "User-Agent") }
        if !src.origin.isEmpty { req.setValue(src.origin, forHTTPHeaderField: "Origin"); req.setValue(src.origin + "/", forHTTPHeaderField: "Referer") }
        return req
    }

    private func fetch(_ src: YtEngine.Source, to out: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let fh = try FileHandle(forWritingTo: out)
        defer { try? fh.close() }
        let size = src.size
        let session = self.session
        guard size >= 1_000_000 else {
            // small or unknown size: one plain request
            guard let req = request(src, range: size > 0 ? (0, size - 1) : nil) else { throw YtError("Bad audio address") }
            let (data, resp) = try await session.data(for: req)
            if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw YtError("download refused (HTTP \(h.statusCode))") }
            try fh.write(contentsOf: data); progress(Int64(data.count), Int64(data.count)); return
        }
        try fh.truncate(atOffset: UInt64(size))
        let sink = FileSink(fh)
        let piece: Int64 = 1_000_000
        let n = Int((size + piece - 1) / piece)
        let reqs: [URLRequest?] = (0..<n).map { i in
            let from = Int64(i) * piece
            return request(src, range: (from, min(size - 1, from + piece - 1)))
        }
        try await withThrowingTaskGroup(of: Void.self) { g in
            var next = 0
            func piece(_ i: Int) -> (@Sendable () async throws -> Void) {
                let from = Int64(i) * 1_000_000, want = Int64(min(size - 1, from + 1_000_000 - 1) - from + 1)
                let req = reqs[i]
                return {
                    guard let req = req else { throw YtError("Bad audio address") }
                    var err: Error = YtError("a piece failed")
                    for tryN in 0..<3 {
                        if tryN > 0 { try await Task.sleep(nanoseconds: UInt64(300_000_000 * tryN)) }
                        do {
                            let (data, resp) = try await session.data(for: req)
                            if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw YtError("download refused (HTTP \(h.statusCode))") }
                            guard Int64(data.count) == want else { throw YtError("short piece") }
                            try await sink.write(data, at: from)
                            progress(await sink.got, size)
                            return
                        } catch is CancellationError { throw CancellationError() }
                        catch { err = error }
                    }
                    throw err
                }
            }
            for _ in 0..<min(4, n) { g.addTask(operation: piece(next)); next += 1 }
            while try await g.next() != nil {
                if next < n { g.addTask(operation: piece(next)); next += 1 }
            }
        }
        progress(size, size)
    }

    // MARK: the pictures and the tags

    nonisolated static func sharpCover(_ thumb: String) async -> Data? {
        guard !thumb.isEmpty else { return nil }
        var urls: [String] = []
        if thumb.contains("ytimg.com") {
            urls.append(thumb.replacingOccurrences(of: #"/(default|mqdefault|hqdefault|sddefault)\.jpg"#, with: "/maxresdefault.jpg", options: .regularExpression))
            urls.append(thumb.replacingOccurrences(of: #"/(default|mqdefault|hqdefault)\.jpg"#, with: "/sddefault.jpg", options: .regularExpression))
        }
        urls.append(thumb.replacingOccurrences(of: #"=w\d+-h\d+[^&]*"#, with: "=w1200-h1200-l90-rj", options: .regularExpression))
        urls.append(thumb)
        var seen = Set<String>()
        for u in urls where seen.insert(u).inserted {
            guard let url = URL(string: u), let (d, r) = try? await URLSession.shared.data(from: url), (r as? HTTPURLResponse)?.statusCode == 200 else { continue }
            if let src = CGImageSourceCreateWithData(d as CFData, nil), let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
               let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int, w >= 480, h >= 360 { return d }
        }
        return nil
    }

    nonisolated static func destination(for t: Track, ext: String) -> URL {
        func clean(_ s: String) -> String {
            let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
            return s.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        }
        let artist = clean(primaryArtist(t.artist)), title = clean(t.title)
        let base = artist.isEmpty ? (title.isEmpty ? t.id : title) : "\(artist) - \(title.isEmpty ? t.id : title)"
        let dir = folder
        var url = dir.appendingPathComponent("\(String(base.prefix(150))).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = dir.appendingPathComponent("\(String(base.prefix(150))) (\(n)).\(ext)"); n += 1 }
        return url
    }

    /// copies the audio into a tidy .m4a with the title, artist, album, year and cover written in (no re-encoding)
    nonisolated static func tag(_ src: URL, to dest: URL, _ t: Track, _ cover: Data?) async throws {
        let asset = AVURLAsset(url: src)
        guard let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { throw YtError("Can't tag this file") }
        ex.outputURL = dest; ex.outputFileType = .m4a
        func item(_ id: AVMetadataIdentifier, _ v: NSCopying & NSObjectProtocol, _ type: String? = nil) -> AVMetadataItem {
            let m = AVMutableMetadataItem(); m.identifier = id; m.value = v; m.extendedLanguageTag = "und"
            if let type = type { m.dataType = type }
            return m
        }
        var items: [AVMetadataItem] = []
        if !t.title.isEmpty { items.append(item(.iTunesMetadataSongName, t.title as NSString)) }
        if !t.artist.isEmpty { items.append(item(.iTunesMetadataArtist, t.artist as NSString)) }
        if !t.album.isEmpty { items.append(item(.iTunesMetadataAlbum, t.album as NSString)) }
        if !t.albumArtist.isEmpty { items.append(item(.iTunesMetadataAlbumArtist, t.albumArtist as NSString)) }
        if !t.year.isEmpty { items.append(item(.iTunesMetadataReleaseDate, t.year as NSString)) }
        if let c = cover { items.append(item(.iTunesMetadataCoverArt, c as NSData, kCMMetadataBaseDataType_JPEG as String)) }
        ex.metadata = items
        await ex.export()
        if ex.status != .completed { throw ex.error ?? YtError("The file couldn't be tagged") }
    }
}
