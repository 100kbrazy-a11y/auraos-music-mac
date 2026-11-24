import SwiftUI
import AppKit
import AVFoundation

// "Export a piece of this song": the part you drag out on the timeline, saved with the lyrics and with what Strata made of their timing,
// as one zip. For when the highlighted words look wrong and someone needs to see exactly what happened there.

enum ClipExport {
    static let maxSeconds = 120.0

    /// writes the zip to Downloads and returns where it is
    @MainActor
    static func export(song: Song, from a: Double, to b: Double) async throws -> URL {
        let store = LyricsStore.shared
        let lines = store.lines, offset = store.offset, wordSynced = store.wordSynced, source = store.sourceLRC
        let timed = try? String(contentsOf: store.alignedURL(song.id), encoding: .utf8)
        let auto = WordSync.shared.auto
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return try await Task.detached(priority: .userInitiated) {
            try build(song: song, from: a, to: b, lines: lines, offset: offset, wordSynced: wordSynced, source: source, timed: timed, auto: auto, version: version)
        }.value
    }

    nonisolated private static func clock(_ t: Double) -> String {
        let t = max(0, t)
        let m = Int(t / 60)
        return String(format: "%d:%05.2f", m, t - Double(m) * 60)
    }

    nonisolated private static func safe(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let t = s.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return String((t.isEmpty ? "song" : t).prefix(50))
    }

    nonisolated private static func wav(_ l: [Float], _ r: [Float], rate: Int) -> Data {
        let n = min(l.count, r.count)
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + n * 4)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(2); u32(UInt32(rate)); u32(UInt32(rate * 4)); u16(4); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(n * 4))
        var body = [Int16](repeating: 0, count: n * 2)
        for i in 0..<n {
            body[i * 2] = Int16(max(-1, min(1, l[i])) * 32767).littleEndian
            body[i * 2 + 1] = Int16(max(-1, min(1, r[i])) * 32767).littleEndian
        }
        body.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }

    nonisolated private static func report(song: Song, a: Double, b: Double, lines: [LyricLine], offset: Double, wordSynced: Bool, hasSource: Bool, hasTimed: Bool, auto: Bool, version: String) -> String {
        var s = "Strata Music for Mac - timing report\n"
        s += "App version: \(version)\n"
        s += "Song: \(song.title) - \(song.shownArtist) - \(song.shownAlbum)\n"
        s += "Length: \(clock(song.duration)), file type: \(song.ext)\n"
        s += "\nclip.wav is this song from \(clock(a)) to \(clock(b)) (\(String(format: "%.1f", b - a)) s, 22 050 Hz stereo). Every time below is a time in the song, not in the clip.\n"
        s += "Lyrics shifted by you: \(String(format: "%+.2f", offset)) s\n"
        s += "Automatic word timing: \(auto ? "on" : "off"); words in the lyrics below come from: \(wordSynced ? "Strata's own listening (lyrics-timed.lrc)" : "the lyrics file or an even spread over each line")\n"
        s += "lyrics-source.lrc: \(hasSource ? "the lyrics as they were found" : "not available (no synced lyrics file was loaded)")\n"
        s += "lyrics-timed.lrc: \(hasTimed ? "what Strata's word timing made from them" : "not available (no word timing has been made for this song)")\n"
        s += "\nLines in this part. Each word is start-end in seconds of the song; \"?\" means the end isn't known and the word runs to the next one.\n\n"
        var any = false
        for (i, l) in lines.enumerated() where !l.text.isEmpty {
            let t = l.time + offset
            let next = i + 1 < lines.count ? lines[i + 1].time + offset : t + 6
            let stop = max(next, l.sungEnd + offset)
            guard stop >= a, t <= b else { continue }
            any = true
            s += "[\(clock(t))] \(l.text)\n"
            s += "    sung until \(clock(l.sungEnd + offset)), next line at \(clock(next)), word times from the file: \(l.tagged ? "yes" : "no (estimated)")\n"
            let w = l.words.map { w -> String in
                let end = w.end.map { String(format: "%.2f", $0 + offset) } ?? "?"
                return "\(w.text.trimmingCharacters(in: .whitespaces)) \(String(format: "%.2f", w.start + offset))-\(end)"
            }
            s += "    " + w.joined(separator: " | ") + "\n"
        }
        if !any { s += "(no lyrics lines fall in this part)\n" }
        return s
    }

    nonisolated private static func build(song: Song, from a: Double, to b: Double, lines: [LyricLine], offset: Double, wordSynced: Bool, source: String, timed: String?, auto: Bool, version: String) throws -> URL {
        let fm = FileManager.default
        let a = max(0, a), b = min(max(b, a + 1), a + maxSeconds)
        let pcm = try PCM22k.load(song.url, from: a, to: b)
        guard pcm.left.count > PCM22k.rate / 2 else { throw AlignError("That part of the song can't be read") }
        let name = "Strata timing - \(safe(song.title)) \(Int(a))-\(Int(b)) s"
        let root = fm.temporaryDirectory.appendingPathComponent("strata-export-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try wav(pcm.left, pcm.right, rate: PCM22k.rate).write(to: folder.appendingPathComponent("clip.wav"))
        if !source.isEmpty { try source.write(to: folder.appendingPathComponent("lyrics-source.lrc"), atomically: true, encoding: .utf8) }
        if let timed, !timed.isEmpty { try timed.write(to: folder.appendingPathComponent("lyrics-timed.lrc"), atomically: true, encoding: .utf8) }
        let text = report(song: song, a: a, b: b, lines: lines, offset: offset, wordSynced: wordSynced, hasSource: !source.isEmpty, hasTimed: !(timed ?? "").isEmpty, auto: auto, version: version)
        try text.write(to: folder.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)

        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? fm.homeDirectoryForCurrentUser
        var dest = downloads.appendingPathComponent("\(name).zip")
        var n = 2
        while fm.fileExists(atPath: dest.path) { dest = downloads.appendingPathComponent("\(name) \(n).zip"); n += 1 }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", folder.path, dest.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw AlignError("Couldn't make the zip file") }
        return dest
    }

    /// the loudness of a song in [count] slices, for drawing it
    nonisolated static func peaks(of url: URL, count: Int = 600) -> [Float] {
        guard let pcm = try? PCM22k.load(url), pcm.left.count > count else { return [] }
        let per = pcm.left.count / count
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            var m: Float = 0
            let from = i * per
            for k in stride(from: from, to: from + per, by: 4) { m = max(m, abs(pcm.left[k]) + abs(pcm.right[k])) }
            out[i] = m
        }
        let top = max(out.max() ?? 1, 0.0001)
        return out.map { sqrt($0 / top) }
    }
}

/// the song drawn as a strip: drag across it to choose the part to export
struct ExportClipSheet: View {
    let song: Song
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var player: Player
    @ObservedObject private var store = LyricsStore.shared
    @State private var peaks: [Float] = []
    @State private var drawing = true
    @State private var a = 0.0
    @State private var b = 0.0
    @State private var anchor: Double?
    @State private var busy = false
    @State private var saved: URL?
    @State private var problem: String?

    private var length: Double { max(0, b - a) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export a piece of this song").font(.title3.weight(.semibold))
            Text("Drag across the timeline to choose the part (up to \(Int(ClipExport.maxSeconds)) seconds). It is saved as one zip in Downloads with the audio, the lyrics, and how Strata timed them, so a wrong spot can be looked at closely.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            timeline.frame(height: 96)

            HStack {
                Text(length > 0 ? "\(fmtTime(a)) – \(fmtTime(b))   (\(Int(length.rounded())) s)" : "Nothing chosen yet").monospacedDigit()
                Spacer()
                Button("Use the part playing now") { around(player.clock.position) }
            }

            if let saved {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Saved in Downloads: \(saved.lastPathComponent)").lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                }
            }
            if let problem { Text(problem).font(.callout).foregroundStyle(.red) }

            HStack {
                Spacer()
                Button(saved == nil ? "Cancel" : "Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Button { run() } label: { busy ? AnyView(HStack { ProgressView().controlSize(.small); Text("Exporting…") }) : AnyView(Text("Export")) }
                    .keyboardShortcut(.defaultAction).disabled(busy || length < 1)
            }
        }
        .padding(24).frame(width: 580)
        .task {
            around(player.clock.position)
            let url = song.url
            peaks = await Task.detached(priority: .utility) { ClipExport.peaks(of: url) }.value
            drawing = false
        }
    }

    private var timeline: some View {
        GeometryReader { g in
            let w = max(1, g.size.width)
            let dur = max(1, song.duration)
            func x(_ t: Double) -> CGFloat { CGFloat(t / dur) * w }
            func time(_ px: CGFloat) -> Double { Double(min(max(px / w, 0), 1)) * dur }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07))
                Canvas { ctx, size in
                    guard !peaks.isEmpty else { return }
                    let step = size.width / CGFloat(peaks.count)
                    for (i, p) in peaks.enumerated() {
                        let h = max(2, CGFloat(p) * size.height * 0.82)
                        let r = CGRect(x: CGFloat(i) * step, y: (size.height - h) / 2, width: max(1, step - 0.6), height: h)
                        ctx.fill(Path(roundedRect: r, cornerRadius: 1), with: .color(.white.opacity(0.35)))
                    }
                    // where each lyric line starts
                    for l in store.lines where !l.text.isEmpty {
                        let px = CGFloat((l.time + store.offset) / dur) * size.width
                        ctx.fill(Path(CGRect(x: px, y: size.height - 7, width: 1, height: 7)), with: .color(.white.opacity(0.5)))
                    }
                }
                if drawing { ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity) }
                // the chosen part
                if length > 0 {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.30))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.accentColor, lineWidth: 2))
                        .frame(width: max(3, x(b) - x(a)), height: g.size.height)
                        .offset(x: x(a))
                }
                PlayheadMark(clock: player.clock, duration: dur, width: w)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if anchor == nil { anchor = time(v.startLocation.x) }
                    let start = anchor ?? 0, cur = time(v.location.x)
                    var lo = min(start, cur), hi = max(start, cur)
                    if hi - lo > ClipExport.maxSeconds { if cur >= start { hi = lo + ClipExport.maxSeconds } else { lo = hi - ClipExport.maxSeconds } }
                    a = lo; b = hi; saved = nil
                }
                .onEnded { _ in
                    if length < 2, let s = anchor { around(s, before: 3, after: 12) }      // just a click: take a short part from there
                    anchor = nil
                })
        }
    }

    private func around(_ t: Double, before: Double = 5, after: Double = 15) {
        let dur = max(1, song.duration)
        a = max(0, t - before)
        b = min(dur, t + after)
        saved = nil
    }

    private func run() {
        busy = true; problem = nil; saved = nil
        let (from, to) = (a, b)
        Task {
            do {
                let url = try await ClipExport.export(song: song, from: from, to: to)
                saved = url
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { problem = error.localizedDescription }
            busy = false
        }
    }
}

/// a thin line where the song is playing now
private struct PlayheadMark: View {
    @ObservedObject var clock: Clock
    let duration: Double
    let width: CGFloat
    var body: some View {
        Rectangle().fill(Color.white).frame(width: 2).offset(x: CGFloat(clock.position / duration) * width - 1).allowsHitTesting(false)
    }
}
