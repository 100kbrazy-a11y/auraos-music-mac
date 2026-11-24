import Foundation
import WebKit

struct Track: Hashable, Identifiable, Codable {
    var id: String
    var title: String
    var artist: String
    var album: String = ""
    var thumb: String = ""
    var track: Int = 0
    var albumArtist: String = ""
    var year: String = ""
}

/// one row of a YouTube Music search
struct YtResult: Identifiable, Hashable {
    var kind: String          // song | album | playlist | artist
    var id: String
    var title: String
    var artist: String
    var album: String
    var thumb: String
    var sub: String
    var duration: Double
}

struct YtError: LocalizedError { var errorDescription: String?; init(_ m: String) { errorDescription = m } }

/// The tiny hidden browser. One WKWebView loaded as https://www.youtube.com, running engine.js (YouTube.js + the proof-of-origin
/// check). It exists only while a search or download needs it and is thrown away a few seconds after the last job. Its network
/// traffic goes out through URLSession; the audio file itself is downloaded natively too.
@MainActor
final class YtEngine: NSObject, WKScriptMessageHandler {
    static let shared = YtEngine()

    private var web: WKWebView?
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var isReady = false
    private var opening = false
    private var calls: [Int: CheckedContinuation<String, Error>] = [:]
    private var seq = 1
    private var epoch = 0
    private var users = 0
    private var failStreak = 0
    private var closer: Task<Void, Never>?
    private let net: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false; c.httpCookieAcceptPolicy = .never
        c.timeoutIntervalForRequest = 40; c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    // MARK: lending the browser out

    /// opens the hidden browser if needed, runs [block], and closes it 15 s after the last user is done
    func use<T>(_ block: () async throws -> T) async throws -> T {
        closer?.cancel(); closer = nil
        users += 1
        defer {
            users -= 1
            if users == 0 {
                closer = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    if !Task.isCancelled { self?.closeIfIdle() }
                }
            }
        }
        do {
            try await open()
            let r = try await block()
            failStreak = 0
            return r
        } catch {
            if error is CancellationError { throw error }
            EngineLog.shared.add("Failed: " + ((error as? YtError)?.errorDescription ?? error.localizedDescription))
            failStreak += 1
            // three failures in a row: start over with a fresh page, even if other jobs are using this one
            if failStreak >= 3 { failStreak = 0; tearDown("Three failures in a row, starting over") }
            else if users <= 1 { tearDown("The YouTube page stopped") }
            throw error
        }
    }

    /// throw the hidden browser away; the next job makes a fresh one
    func reset() { tearDown("The YouTube page was reset") }

    private func closeIfIdle() { if users == 0 { tearDown("closed") } }

    private func open() async throws {
        if isReady { return }
        if opening { try await waitReady(); return }
        opening = true
        guard let url = Bundle.main.url(forResource: "engine", withExtension: "js"), let js = try? String(contentsOf: url, encoding: .utf8) else {
            opening = false
            throw YtError("This copy of Strata Music has no YouTube engine inside. Update to the newest version.")
        }
        let conf = WKWebViewConfiguration()
        conf.websiteDataStore = .nonPersistent()
        let ucc = WKUserContentController()
        ucc.add(WeakHandler(self), name: "strata")
        ucc.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        conf.userContentController = ucc
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 4, height: 4), configuration: conf)
        w.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
        web = w
        w.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: URL(string: "https://www.youtube.com/"))
        let ep = epoch
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            if let s = self, s.epoch == ep, !s.isReady { s.tearDown("The YouTube page didn't start") }
        }
        try await waitReady()
    }

    private func waitReady() async throws {
        if isReady { return }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in readyWaiters.append(c) }
    }

    private func tearDown(_ why: String) {
        EngineLog.shared.add("Closed the YouTube page: \(why)")
        let pending = calls; calls = [:]
        for (_, c) in pending { c.resume(throwing: YtError(why)) }
        let waiters = readyWaiters; readyWaiters = []
        for c in waiters { c.resume(throwing: YtError(why)) }
        if let w = web {
            w.stopLoading()
            w.configuration.userContentController.removeScriptMessageHandler(forName: "strata")
            w.configuration.userContentController.removeAllUserScripts()
            w.loadHTMLString("", baseURL: nil)
        }
        web = nil; isReady = false; opening = false; epoch += 1
    }

    // MARK: calling into engine.js

    func call(_ fn: String, _ argJson: String, timeout: Double = 120) async throws -> String {
        guard let w = web, isReady else { throw YtError("The YouTube page is closed") }
        let id = seq; seq += 1
        let script = "__eng.run(\(id),\(Self.q(fn)),\(Self.q(argJson)))"
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            calls[id] = c
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
                if let c = self?.calls.removeValue(forKey: id) { c.resume(throwing: YtError("YouTube took too long to answer")) }
            }
            w.evaluateJavaScript(script) { _, err in
                // the script only starts the job; an error here means the page itself is broken
                if let err = err, (err as NSError).domain == WKError.errorDomain, (err as NSError).code != WKError.javaScriptResultTypeIsUnsupported.rawValue {
                    Task { @MainActor in if let c = self.calls.removeValue(forKey: id) { c.resume(throwing: YtError(err.localizedDescription)) } }
                }
            }
        }
    }

    nonisolated static func q(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed), let t = String(data: d, encoding: .utf8) else { return "\"\"" }
        return t
    }

    // MARK: JS -> Swift

    nonisolated func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let t = m["t"] as? String else { return }
        Task { @MainActor in self.handle(t, m) }
    }

    private func handle(_ t: String, _ m: [String: Any]) {
        switch t {
        case "ready":
            isReady = true; opening = false
            let w = readyWaiters; readyWaiters = []
            for c in w { c.resume() }
        case "result":
            if let id = (m["id"] as? NSNumber)?.intValue, let c = calls.removeValue(forKey: id) { c.resume(returning: (m["j"] as? String) ?? "null") }
        case "fail":
            if let id = (m["id"] as? NSNumber)?.intValue, let c = calls.removeValue(forKey: id) { c.resume(throwing: YtError((m["m"] as? String) ?? "YouTube didn't answer")) }
        case "log":
            EngineLog.shared.add("[page] " + (m["m"] as? String ?? ""))
        case "fetch":
            guard let id = (m["id"] as? NSNumber)?.intValue, let u = m["u"] as? String, let url = URL(string: u) else { return }
            let method = (m["m"] as? String) ?? "GET"
            let headers = (try? JSONSerialization.jsonObject(with: Data(((m["h"] as? String) ?? "{}").utf8))) as? [String: Any] ?? [:]
            let body = (m["b"] as? String) ?? ""
            fetch(id, url, method, headers, body)
        default: break
        }
    }

    /// the page's network requests, made natively (so there's no cross-site blocking, and cookies stay out of it)
    private func fetch(_ id: Int, _ url: URL, _ method: String, _ headers: [String: Any], _ body: String) {
        var req = URLRequest(url: url); req.httpMethod = method; req.timeoutInterval = 40
        for (k, v) in headers {
            let lk = k.lowercased()
            if lk == "accept-encoding" || lk == "host" || lk == "content-length" || lk == "connection" { continue }
            req.setValue("\(v)", forHTTPHeaderField: k)
        }
        if method != "GET" && method != "HEAD" { req.httpBody = Data(body.utf8) }
        let session = net
        Task.detached { [weak self] in
            var js: String
            do {
                let (data, resp) = try await session.data(for: req)
                let h = resp as? HTTPURLResponse
                var hs: [String: String] = [:]
                for (k, v) in h?.allHeaderFields ?? [:] { hs["\(k)"] = "\(v)" }
                let hj = (try? JSONSerialization.data(withJSONObject: hs)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                js = "__fx(\(id),\(h?.statusCode ?? 200),\(YtEngine.q(hj)),\(YtEngine.q(data.base64EncodedString())))"
            } catch {
                js = "__fxe(\(id),\(YtEngine.q(error.localizedDescription)))"
            }
            let script = js
            await MainActor.run { self?.web?.evaluateJavaScript(script, completionHandler: nil) }
        }
    }

    // MARK: the engine's functions, as Swift

    private func run(_ fn: String, _ arg: String, timeout: Double = 120) async throws -> Any {
        let text = try await call(fn, arg, timeout: timeout)
        guard let o = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed) else { throw YtError("YouTube sent something unreadable") }
        return o
    }

    func search(_ q: String, type: String) async throws -> [YtResult] {
        try await use {
            let arg = (try? JSONSerialization.data(withJSONObject: ["q": q, "type": type])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let arr = (try await run("search", arg, timeout: 60)) as? [[String: Any]] ?? []
            return arr.map {
                YtResult(kind: $0["kind"] as? String ?? type, id: $0["id"] as? String ?? "", title: $0["title"] as? String ?? "", artist: $0["artist"] as? String ?? "",
                         album: $0["album"] as? String ?? "", thumb: $0["thumb"] as? String ?? "", sub: $0["sub"] as? String ?? "", duration: ($0["duration"] as? NSNumber)?.doubleValue ?? 0)
            }
        }
    }

    private static func tracks(_ a: Any?) -> [Track] {
        (a as? [[String: Any]] ?? []).compactMap {
            guard let id = $0["id"] as? String else { return nil }
            return Track(id: id, title: $0["title"] as? String ?? "", artist: $0["artist"] as? String ?? "", album: $0["album"] as? String ?? "", thumb: $0["thumb"] as? String ?? "",
                         track: ($0["track"] as? NSNumber)?.intValue ?? 0, albumArtist: $0["albumartist"] as? String ?? "", year: $0["year"] as? String ?? "")
        }
    }

    /// the songs of an album or playlist (kind + id), or of a pasted YouTube link
    func tracks(kind: String? = nil, id: String? = nil, link: String? = nil, artist: String = "") async throws -> (title: String, tracks: [Track]) {
        try await use {
            var o: [String: Any] = [:]
            if let l = link { o["link"] = l } else { o["kind"] = kind ?? "song"; o["id"] = id ?? ""; if !artist.isEmpty { o["artist"] = artist } }
            let arg = (try? JSONSerialization.data(withJSONObject: o)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let j = (try await run("tracks", arg, timeout: 120)) as? [String: Any] ?? [:]
            return (j["title"] as? String ?? "", Self.tracks(j["tracks"]))
        }
    }

    var isWarm: Bool { isReady && web != nil }

    /// songs YouTube Music thinks go with this one (by id, or by searching [q])
    func radio(id: String?, q: String) async throws -> [Track] {
        try await use {
            var o: [String: Any] = ["q": q]
            if let id = id, !id.isEmpty { o["id"] = id }
            let arg = (try? JSONSerialization.data(withJSONObject: o)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let j = (try await run("radio", arg, timeout: 90)) as? [String: Any] ?? [:]
            return Self.tracks(j["tracks"])
        }
    }

    struct ArtistPage { var name: String; var thumb: String; var albums: [YtResult]; var top: [Track] }
    func artist(_ id: String) async throws -> ArtistPage {
        try await use {
            let j = (try await run("artist", Self.q(id), timeout: 120)) as? [String: Any] ?? [:]
            let albums = (j["albums"] as? [[String: Any]] ?? []).map {
                YtResult(kind: "album", id: $0["id"] as? String ?? "", title: $0["title"] as? String ?? "", artist: j["name"] as? String ?? "", album: $0["title"] as? String ?? "",
                         thumb: $0["thumb"] as? String ?? "", sub: [($0["single"] as? Bool ?? false) ? "Single / EP" : "Album", $0["year"] as? String ?? ""].filter { !$0.isEmpty }.joined(separator: " · "), duration: 0)
            }
            return ArtistPage(name: j["name"] as? String ?? "", thumb: j["thumb"] as? String ?? "", albums: albums, top: Self.tracks(j["top"]))
        }
    }

    /// everything about one song needed to download it
    struct Source { var url: String; var size: Int64; var ext: String; var ua: String; var origin: String; var kbps: Int; var title: String; var artist: String; var duration: Int }
    func source(for id: String) async throws -> Source {
        try await use {
            let j = (try await run("audio", Self.q(id), timeout: 120)) as? [String: Any] ?? [:]
            guard let url = j["url"] as? String, !url.isEmpty else { throw YtError("YouTube gave no audio address") }
            return Source(url: url, size: (j["size"] as? NSNumber)?.int64Value ?? 0, ext: j["ext"] as? String ?? "m4a", ua: j["ua"] as? String ?? "", origin: j["origin"] as? String ?? "",
                          kbps: (j["kbps"] as? NSNumber)?.intValue ?? 0, title: j["title"] as? String ?? "", artist: j["artist"] as? String ?? "", duration: (j["duration"] as? NSNumber)?.intValue ?? 0)
        }
    }
}

/// WKUserContentController keeps its handlers alive; this keeps the engine from being kept alive by it
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: YtEngine?
    init(_ t: YtEngine) { target = t }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) { target?.userContentController(ucc, didReceive: message) }
}
