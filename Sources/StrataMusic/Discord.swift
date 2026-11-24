import Foundation
import Darwin

/// Talks to the Discord app on this Mac over its local socket (the same way Discord's own Rich Presence does): no account, no sign-in.
final class DiscordIPC {
    private var fd: Int32 = -1
    private let clientID: String
    init(clientID: String) { self.clientID = clientID }

    var connected: Bool { fd >= 0 }

    func connect() -> Bool {
        disconnect()
        var dirs: [String] = []
        if let t = ProcessInfo.processInfo.environment["TMPDIR"] { dirs.append(t) }
        dirs.append(NSTemporaryDirectory()); dirs.append("/tmp/")
        for dir in dirs {
            for i in 0..<10 {
                let path = (dir.hasSuffix("/") ? dir : dir + "/") + "discord-ipc-\(i)"
                if !FileManager.default.fileExists(atPath: path) { continue }
                let s = socket(AF_UNIX, SOCK_STREAM, 0)
                if s < 0 { continue }
                var one: Int32 = 1
                setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                var addr = sockaddr_un()
                addr.sun_family = sa_family_t(AF_UNIX)
                let bytes = Array(path.utf8CString)
                if bytes.count > MemoryLayout.size(ofValue: addr.sun_path) { Darwin.close(s); continue }
                withUnsafeMutablePointer(to: &addr.sun_path) { p in
                    p.withMemoryRebound(to: CChar.self, capacity: bytes.count) { dst in
                        for (k, b) in bytes.enumerated() { dst[k] = b }
                    }
                }
                let len = socklen_t(MemoryLayout<sockaddr_un>.size)
                let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, len) } }
                if r == 0 {
                    fd = s
                    if handshake() { return true }
                    disconnect()
                } else { Darwin.close(s) }
            }
        }
        return false
    }

    func disconnect() { if fd >= 0 { Darwin.close(fd); fd = -1 } }

    private func handshake() -> Bool {
        guard send(op: 0, ["v": 1, "client_id": clientID]) else { return false }
        guard let (op, _) = readFrame(timeoutMs: 2500) else { return false }
        return op != 2
    }

    private func send(op: Int32, _ obj: [String: Any]) -> Bool {
        guard fd >= 0, let body = try? JSONSerialization.data(withJSONObject: obj) else { return false }
        var header = Data()
        var o = op.littleEndian, l = Int32(body.count).littleEndian
        withUnsafeBytes(of: &o) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: &l) { header.append(contentsOf: $0) }
        let packet = header + body
        let n = packet.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, packet.count, 0) }
        return n == packet.count
    }

    private func readExactly(_ count: Int, timeoutMs: Int32) -> Data? {
        var out = Data()
        while out.count < count {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&pfd, 1, timeoutMs) <= 0 { return nil }
            var buf = [UInt8](repeating: 0, count: count - out.count)
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { return nil }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }

    private func readFrame(timeoutMs: Int32) -> (Int32, Data)? {
        guard fd >= 0, let h = readExactly(8, timeoutMs: timeoutMs) else { return nil }
        let op = h.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int32.self) }.littleEndian
        let len = Int(h.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int32.self) }.littleEndian)
        if len <= 0 { return (op, Data()) }
        guard let body = readExactly(len, timeoutMs: timeoutMs) else { return nil }
        return (op, body)
    }

    /// nil clears the status
    func setActivity(_ activity: [String: Any]?) -> Bool {
        if !connected, !connect() { return false }
        let payload: [String: Any] = ["cmd": "SET_ACTIVITY", "args": ["pid": Int(getpid()), "activity": activity ?? NSNull()] as [String: Any], "nonce": UUID().uuidString]
        if !send(op: 1, payload) { disconnect(); return false }
        while let _ = readFrame(timeoutMs: 0) { }      // keep Discord's answers from piling up
        return true
    }
}

/// what the app shows on your Discord profile
final class Discord {
    static let shared = Discord()
    private let q = DispatchQueue(label: "strata.discord")
    private let ipc = DiscordIPC(clientID: "1573427664281407609")
    private var covers: [String: String] = [:]          // album → picture address ("" = none found)
    private var asked = Set<String>()
    private var lastKey = ""
    private var lastStart = 0.0
    private var shown = false
    private var latest: (Song?, Bool, Double, Double) = (nil, false, 0, 0)

    func update(song: Song?, playing: Bool, position: Double, duration: Double) {
        q.async { [self] in
            latest = (song, playing, position, duration)
            push()
        }
    }

    private func push() {
        let (song, playing, position, duration) = latest
        let d = UserDefaults.standard
        let on = d.bool(forKey: "discordOn")
        let hidePaused = d.object(forKey: "discordHidePaused") as? Bool ?? true
        let showCover = d.object(forKey: "discordCover") as? Bool ?? true
        let timeline = d.object(forKey: "discordTimeline") as? Bool ?? true
        guard on, let s = song, playing || !hidePaused else {
            if shown { _ = ipc.setActivity(nil); shown = false; lastKey = "" }
            if !on { ipc.disconnect() }
            return
        }
        let now = Date().timeIntervalSince1970 * 1000
        let start = playing && timeline ? now - position * 1000 : 0
        var image = ""
        if showCover {
            image = covers[s.albumKey] ?? ""
            if covers[s.albumKey] == nil, asked.insert(s.albumKey).inserted {
                let artist = s.artistKey, album = s.album.isEmpty ? s.title : s.album, key = s.albumKey
                Task.detached { [self] in
                    let url = await Self.fetchCover(artist: artist, album: album)
                    q.async { self.covers[key] = url; self.lastKey = ""; if !url.isEmpty { self.push() } else { self.asked.remove(key) } }
                }
            }
        }
        let key = [s.id, "\(playing)", image, "\(timeline)", "\(showCover)"].joined(separator: "|")
        let seeked = playing && timeline && lastStart != 0 && abs(start - lastStart) > 3000
        if key == lastKey && !seeked { return }
        lastKey = key; lastStart = start
        var act: [String: Any] = ["type": 2, "details": pad(s.title)]
        if !s.artist.isEmpty { act["state"] = pad(s.artist) }
        if start > 0 {
            var ts: [String: Any] = ["start": Int64(start)]
            if duration > 0 { ts["end"] = Int64(start + duration * 1000) }
            act["timestamps"] = ts
        }
        var assets: [String: Any] = [:]
        if !image.isEmpty { assets["large_image"] = image }
        if !s.album.isEmpty { assets["large_text"] = pad(s.album) }
        if !assets.isEmpty { act["assets"] = assets }
        if ipc.setActivity(act) { shown = true } else { lastKey = "" }
    }

    private func pad(_ s: String) -> String { let t = String(s.prefix(128)); return t.count < 2 ? t + " " : t }

    private static func fetchCover(artist: String, album: String) async -> String {
        var comp = URLComponents(string: "https://itunes.apple.com/search")!
        comp.queryItems = [URLQueryItem(name: "term", value: "\(artist) \(album)"), URLQueryItem(name: "entity", value: "album"), URLQueryItem(name: "limit", value: "1")]
        guard let u = comp.url, let (d, _) = try? await URLSession.shared.data(from: u),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let r = (j["results"] as? [[String: Any]])?.first,
              let a = r["artworkUrl100"] as? String else { return "" }
        return a.replacingOccurrences(of: "100x100bb", with: "600x600bb")
    }
}
