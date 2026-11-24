import Foundation
import AVFoundation
import Accelerate
import COnnx

// Precise word timing: Meta's MMS forced-alignment model (int8, run with ONNX Runtime) listens to a song and says when each letter is sung.
// The lyric lines already have times; for every line this finds the words inside a small window around it, so the lit word follows the voice.

struct AlignError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

// MARK: - the model's alphabet

enum MMS {
    /// the model's labels, in its order: blank, 26 letters and an apostrophe (the last, "*", only stands for "anything else" and is never used here)
    static let labels = Array("-aienoutsrmkldghybpwcvjzf'qx*")
    static let index: [Character: Int] = {
        var d: [Character: Int] = [:]
        for (i, c) in labels.enumerated() where c != "-" && c != "*" { d[c] = i }
        return d
    }()

    /// letters of a romanised word as label numbers; everything the model has no letter for is dropped
    static func tokens(of s: String) -> [Int] {
        let t = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        var out: [Int] = []
        for ch in t {
            if ch == "\u{2019}" || ch == "\u{2018}" || ch == "`" { out.append(index["'"] ?? 0) }
            else if let i = index[ch] { out.append(i) }
        }
        return out
    }
}

/// any script in Latin letters, for the model
enum Roman {
    static func isPlain(_ s: String) -> Bool { s.unicodeScalars.allSatisfy { $0.value <= 0x24F } }

    /// "ja" for lines with kana, "zh" for lines with only Han characters, otherwise nil (the generic transliteration is used)
    static func locale(for s: String) -> String? {
        var han = false
        for u in s.unicodeScalars {
            switch u.value {
            case 0x3040...0x30FF: return "ja"
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: han = true
            default: break
            }
        }
        return han ? "zh" : nil
    }

    static func toLatin(_ s: String) -> String {
        if isPlain(s) { return s }
        return s.applyingTransform(.toLatin, reverse: false) ?? s
    }

    /// the words the system's tokenizer finds (it knows how kanji are read in context), each with its Latin transcription
    static func tokenise(_ s: String, locale: String) -> [(range: NSRange, latin: String)] {
        let cf = s as CFString
        let len = CFStringGetLength(cf)
        guard len > 0, let tok = CFStringTokenizerCreate(kCFAllocatorDefault, cf, CFRange(location: 0, length: len), kCFStringTokenizerUnitWord, CFLocaleCreate(kCFAllocatorDefault, CFLocaleIdentifier(rawValue: locale as CFString))) else { return [] }
        var out: [(NSRange, String)] = []
        while CFStringTokenizerAdvanceToNextToken(tok) != [] {
            let r = CFStringTokenizerGetCurrentTokenRange(tok)
            let ns = NSRange(location: r.location, length: r.length)
            let attr = CFStringTokenizerCopyCurrentTokenAttribute(tok, kCFStringTokenizerAttributeLatinTranscription)
            var latin = (attr as? String) ?? ""
            if latin.isEmpty { latin = toLatin((s as NSString).substring(with: ns)) }
            out.append((ns, latin))
        }
        return out
    }

    /// the letters sung in each piece of a line. Lines written without spaces (Japanese, Chinese) are read as a whole, then each reading is given to the piece it starts in.
    static func pieceTokens(_ pieces: [String], spaced: Bool) -> [[Int]] {
        let joined = pieces.joined()
        let loc = locale(for: joined)
        if !spaced, let loc, !isPlain(joined) {
            var out = [[Int]](repeating: [], count: pieces.count)
            var starts: [Int] = []
            var acc = 0
            for p in pieces { starts.append(acc); acc += (p as NSString).length }
            for t in tokenise(joined, locale: loc) {
                var idx = 0
                for (i, s) in starts.enumerated() where s <= t.range.location { idx = i }
                out[idx] += MMS.tokens(of: t.latin)
            }
            return out
        }
        return pieces.map { p in
            if isPlain(p) { return MMS.tokens(of: p) }
            if let loc { return MMS.tokens(of: tokenise(p, locale: loc).map { $0.latin }.joined(separator: " ")) }
            return MMS.tokens(of: toLatin(p))
        }
    }
}

// MARK: - the song as the model wants it

enum PCM16k {
    /// the whole song as 16 kHz mono floats
    static func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFmt = file.processingFormat
        guard inFmt.sampleRate > 0,
              let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inFmt, to: outFmt) else { throw AlignError("This file's audio can't be read") }
        let inCap: AVAudioFrameCount = 32768
        let outCap = AVAudioFrameCount(Double(inCap) * 16000 / inFmt.sampleRate) + 2048
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: inCap),
              let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap) else { throw AlignError("Not enough memory to read the song") }
        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) / inFmt.sampleRate * 16000) + 16000)
        var ended = false
        while true {
            outBuf.frameLength = 0
            var err: NSError?
            let status = conv.convert(to: outBuf, error: &err) { _, inStatus in
                if ended { inStatus.pointee = .endOfStream; return nil }
                inBuf.frameLength = 0
                do { try file.read(into: inBuf, frameCount: inCap) } catch { ended = true; inStatus.pointee = .endOfStream; return nil }
                if inBuf.frameLength == 0 { ended = true; inStatus.pointee = .endOfStream; return nil }
                inStatus.pointee = .haveData
                return inBuf
            }
            if let c = outBuf.floatChannelData?[0], outBuf.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: c, count: Int(outBuf.frameLength)))
            }
            if status == .error { throw err ?? AlignError("This file's audio can't be converted") }
            if status == .endOfStream { break }
            if outBuf.frameLength == 0 && status != .haveData { break }
        }
        return samples
    }
}

// MARK: - the model

/// state shared by the threads that listen to the song, behind a lock
private final class Shared: @unchecked Sendable {
    let lock = NSLock()
    var results: [[Float]?]
    var classes = 0
    var failure: Error?
    var finished = 0
    init(count: Int) { results = [[Float]?](repeating: nil, count: count) }
}

/// the cores that do the real work (not the slow efficiency cores of Apple silicon)
enum Cores {
    static let fast: Int = {
        for key in ["hw.perflevel0.physicalcpu", "hw.physicalcpu"] {
            var v: Int32 = 0
            var size = MemoryLayout<Int32>.size
            if sysctlbyname(key, &v, &size, nil, 0) == 0, v > 0 { return Int(v) }
        }
        return max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
    }()
}

/// keeps the loaded model for a couple of minutes so the next song doesn't pay for loading it again
final class RunnerCache: @unchecked Sendable {
    static let shared = RunnerCache()
    private let lock = NSLock()
    private var runner: MMSRunner?
    private var path = ""
    private var used = Date()

    func get(_ path: String) throws -> MMSRunner {
        lock.lock(); defer { lock.unlock() }
        used = Date()
        if let r = runner, self.path == path { return r }
        runner = nil
        let r = try MMSRunner(path: path)
        runner = r
        self.path = path
        return r
    }

    func done() {
        lock.lock(); used = Date(); lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120) { [self] in
            lock.lock(); defer { lock.unlock() }
            if Date().timeIntervalSince(used) >= 119 { runner = nil }
        }
    }

    func drop() { lock.lock(); runner = nil; lock.unlock() }
}

final class MMSRunner: @unchecked Sendable {
    private let handle: OpaquePointer
    static let core = 320_000, ctx = 10_240          // 20 s of audio per piece, plus 0.64 s each side that a piece only listens to (whole numbers of 320-sample frames)

    init(path: String) throws {
        var err = [CChar](repeating: 0, count: 512)
        let threads = Int32(max(2, Cores.fast - 1))
        let cap = err.count
        guard let h = strata_ort_open(path, threads, &err, cap) else { throw AlignError(String(cString: err)) }
        handle = h
    }
    deinit { strata_ort_close(handle) }

    /// log-probabilities of the model's labels for every 20 ms of the song (frames × classes). Only the stretches that hold lyrics are listened to
    /// (the rest stays zero), several pieces at a time, and what was worked out is remembered in [cache].
    func emissions(_ wave: [Float], needed: [(Double, Double)], cache: URL?, progress: @escaping @Sendable (Double) -> Void) throws -> (data: [Float], classes: Int) {
        let core = Self.core, coreFrames = Self.core / 320
        let n = wave.count
        let globalFrames = max(0, (n - 400) / 320 + 1)
        let K = (n + core - 1) / core
        var want = [Bool](repeating: needed.isEmpty, count: K)
        for (s, e) in needed {
            let k0 = max(0, Int(s * 16000) / core), k1 = min(K - 1, Int(e * 16000) / core)
            if k0 <= k1 { for k in k0...k1 { want[k] = true } }
        }
        var have = [Bool](repeating: false, count: K)
        var data: [Float] = []
        var classes = 0
        if let u = cache, let c = Self.readCache(u, chunks: K, frames: globalFrames) { (classes, have, data) = c }
        let todo = (0..<K).filter { want[$0] && !have[$0] }
        if !todo.isEmpty {
            var mean: Float = 0, msq: Float = 0
            vDSP_meanv(wave, 1, &mean, vDSP_Length(n))
            vDSP_measqv(wave, 1, &msq, vDSP_Length(n))
            let m = mean
            let inv = 1 / sqrt(max(msq - mean * mean, 1e-8))
            let shared = Shared(count: todo.count)
            let workers = min(todo.count, 3)
            DispatchQueue.concurrentPerform(iterations: workers) { w in
                var i = w
                while i < todo.count {
                    shared.lock.lock(); let stop = shared.failure != nil; shared.lock.unlock()
                    if stop { return }
                    do {
                        let (slice, c) = try self.chunk(wave, k: todo[i], mean: m, inv: inv, globalFrames: globalFrames)
                        shared.lock.lock()
                        shared.results[i] = slice
                        if c > 0 { shared.classes = c }
                        shared.finished += 1
                        let f = Double(shared.finished) / Double(todo.count)
                        shared.lock.unlock()
                        progress(f)
                    } catch {
                        shared.lock.lock(); if shared.failure == nil { shared.failure = error }; shared.lock.unlock()
                        return
                    }
                    i += workers
                }
            }
            if let f = shared.failure { throw f }
            if shared.classes > 0 {
                if classes != 0 && classes != shared.classes { have = [Bool](repeating: false, count: K); data = [] }
                classes = shared.classes
                if data.isEmpty { data = [Float](repeating: 0, count: globalFrames * classes) }
                for (i, k) in todo.enumerated() {
                    guard let slice = shared.results[i] else { continue }
                    let off = k * coreFrames * classes
                    let count = min(slice.count, data.count - off)
                    if count > 0 { data.replaceSubrange(off..<(off + count), with: slice[0..<count]) }
                    have[k] = true
                }
                if let u = cache { Self.writeCache(u, classes: classes, have: have, frames: globalFrames, data: data) }
            }
        }
        guard classes > 0, !data.isEmpty else { throw AlignError("There is nothing to listen to in this song") }
        return (data, classes)
    }

    /// the log-probabilities for the frames of one piece
    private func chunk(_ wave: [Float], k: Int, mean: Float, inv: Float, globalFrames: Int) throws -> ([Float], Int) {
        let core = Self.core, ctx = Self.ctx, coreFrames = Self.core / 320
        let n = wave.count
        let coreStart = k * core, coreEnd = min(n, coreStart + core)
        let a = max(0, coreStart - ctx), b = min(n, coreEnd + ctx)
        guard b - a >= 1600 else { return ([], 0) }
        let input = wave[a..<b].map { ($0 - mean) * inv }
        let (logp, frames, c) = try run(input)
        let g0 = k * coreFrames
        let g1 = (coreEnd == n) ? globalFrames : min(globalFrames, (k + 1) * coreFrames)
        let i0 = g0 - a / 320
        let i1 = min(frames, g1 - a / 320)
        guard i1 > i0, i0 >= 0 else { return ([], c) }
        return (Array(logp[(i0 * c)..<(i1 * c)]), c)
    }

    // the remembered results: a small header, which pieces are in, then all the numbers
    private static func writeCache(_ u: URL, classes: Int, have: [Bool], frames: Int, data: [Float]) {
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        var d = Data()
        for v in [0x53544D32, classes, have.count, frames] { var x = Int32(v); withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: have.map { $0 ? UInt8(1) : UInt8(0) })
        data.withUnsafeBytes { d.append(contentsOf: $0) }
        try? d.write(to: u, options: .atomic)
    }

    private static func readCache(_ u: URL, chunks K: Int, frames: Int) -> (Int, [Bool], [Float])? {
        guard let d = try? Data(contentsOf: u), d.count > 16 else { return nil }
        func int(_ o: Int) -> Int { Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: Int32.self) }) }
        guard int(0) == 0x53544D32, int(8) == K, int(12) == frames else { return nil }
        let c = int(4)
        guard c > 1, frames > 0, d.count == 16 + K + frames * c * 4 else { return nil }
        let have = (0..<K).map { d[16 + $0] != 0 }
        var data = [Float](repeating: 0, count: frames * c)
        data.withUnsafeMutableBytes { $0.copyBytes(from: d[(16 + K)...]) }
        return (c, have, data)
    }

    private func run(_ chunk: [Float]) throws -> ([Float], Int, Int) {
        var err = [CChar](repeating: 0, count: 512)
        var out: UnsafeMutablePointer<Float>? = nil
        var f64: Int64 = 0, c64: Int64 = 0
        let n = Int64(chunk.count), cap = err.count
        let rc = chunk.withUnsafeBufferPointer { strata_ort_run(handle, $0.baseAddress, n, &out, &f64, &c64, &err, cap) }
        guard rc == 0, let p = out else { throw AlignError(String(cString: err)) }
        defer { strata_ort_free(p) }
        var frames = Int(f64), c = Int(c64)
        guard frames > 0, c > 1 else { throw AlignError("The model's answer has an unexpected shape") }
        var x = Array(UnsafeBufferPointer(start: p, count: frames * c))

        if c > 64 && frames <= 64 {            // [classes, frames] instead of [frames, classes]
            var t = [Float](repeating: 0, count: x.count)
            for f in 0..<c { for k in 0..<frames { t[f * frames + k] = x[k * c + f] } }
            // here dims were (classes, frames) read as (frames, classes), so swap them
            let swappedFrames = c, swappedClasses = frames
            x = t; frames = swappedFrames; c = swappedClasses
        }
        // the model hands out raw scores: log-softmax each frame
        for f in 0..<frames {
            let base = f * c
            var m = -Float.infinity
            for k in 0..<c { m = max(m, x[base + k]) }
            var sum: Float = 0
            for k in 0..<c { sum += exp(x[base + k] - m) }
            let lse = m + log(sum)
            for k in 0..<c { x[base + k] -= lse }
        }
        return (x, frames, c)
    }
}

// MARK: - lining the words up

enum Aligner {
    static let frameSeconds = 0.02

    /// the first frame of each letter on the most likely path through [tokens] (CTC forced alignment)
    static func ctcStarts(_ e: [Float], base: Int, frames T: Int, classes C: Int, tokens: [Int]) -> [Int]? {
        let L = tokens.count
        guard L > 0 else { return nil }
        let S = 2 * L + 1
        var need = L
        if L > 1 { for j in 1..<L where tokens[j] == tokens[j - 1] { need += 1 } }
        guard T >= need else { return nil }
        var prev = [Float](repeating: -Float.infinity, count: S)
        var cur = prev
        var back = [UInt8](repeating: 0, count: T * S)
        prev[0] = e[base * C]
        prev[1] = e[base * C + tokens[0]]
        if T > 1 {
            for t in 1..<T {
                let row = (base + t) * C
                for s in 0..<S {
                    let lab = s % 2 == 0 ? 0 : tokens[s / 2]
                    var best = prev[s]
                    var from: UInt8 = 0
                    if s >= 1, prev[s - 1] > best { best = prev[s - 1]; from = 1 }
                    if s >= 2, s % 2 == 1, tokens[s / 2] != tokens[s / 2 - 1], prev[s - 2] > best { best = prev[s - 2]; from = 2 }
                    cur[s] = best + e[row + lab]
                    back[t * S + s] = from
                }
                swap(&prev, &cur)
            }
        }
        var s = (prev[S - 2] > prev[S - 1]) ? S - 2 : S - 1
        guard prev[s] > -Float.infinity else { return nil }
        var first = [Int](repeating: -1, count: L)
        var t = T - 1
        while t >= 0 {
            if s % 2 == 1 { first[s / 2] = t }
            if t > 0 { s -= Int(back[t * S + s]) }
            t -= 1
        }
        return first.allSatisfy { $0 >= 0 } ? first : nil
    }

    /// when each piece of a line is sung (in audio time), or nil when the line can't be lined up
    static func alignLine(_ pieces: [String], spaced: Bool, ws: Double, we: Double, em: [Float], classes C: Int, frames: Int) -> [Double]? {
        let pt = Roman.pieceTokens(pieces, spaced: spaced)
        var flat: [Int] = [], owner: [Int] = []
        for (p, t) in pt.enumerated() { for x in t { flat.append(x); owner.append(p) } }
        guard !flat.isEmpty else { return nil }
        let f0 = max(0, Int(ws / frameSeconds))
        let f1 = min(frames, Int(we / frameSeconds) + 1)
        guard f1 - f0 > flat.count + 2, let first = ctcStarts(em, base: f0, frames: f1 - f0, classes: C, tokens: flat) else { return nil }
        let n = pieces.count
        var st = [Double?](repeating: nil, count: n)
        for j in flat.indices where st[owner[j]] == nil { st[owner[j]] = Double(f0 + first[j]) * frameSeconds }
        // pieces with no letters of their own (punctuation, the rest of a kanji reading) sit evenly between their neighbours
        var out = [Double](repeating: 0, count: n)
        var last = -1
        for p in 0..<n {
            guard let v = st[p] else { continue }
            if last + 1 < p {
                let tA = last >= 0 ? out[last] : max(ws, v - 0.2 * Double(p + 1))
                for k in (last + 1)..<p { out[k] = tA + (v - tA) * Double(k - last) / Double(p - last) }
            }
            out[p] = v
            last = p
        }
        guard last >= 0 else { return nil }
        if last < n - 1 { for k in (last + 1)..<n { out[k] = min(we, out[last] + 0.25 * Double(k - last)) } }
        for i in 1..<max(n, 1) where i < n { out[i] = max(out[i], out[i - 1]) }
        return out
    }

    nonisolated static func stamp(_ t: Double) -> String {
        let t = max(0, t)
        let m = Int(t / 60)
        return String(format: "%02d:%05.2f", m, t - Double(m) * 60)
    }

    /// aligns a whole song. The result is an enhanced .lrc (a time before each word) in the song's own audio time, or nil if no line could be lined up.
    /// the stretch of the song a line is sung in (audio time): from just before its stamp to just after the next line starts
    static func window(_ lines: [LyricLine], _ i: Int, offset: Double, seconds: Double) -> (Double, Double)? {
        let line = lines[i]
        guard !line.text.isEmpty, !line.words.isEmpty else { return nil }
        let base = line.time + offset
        let next = i + 1 < lines.count ? lines[i + 1].time + offset : base + 10
        var we = max(next + 0.2, base + 1.5)
        we = min(we, base + 4 + Double(line.text.count) * 0.25)
        we = min(we, seconds)
        let ws = max(0, base - 0.6)
        return we > ws ? (ws, we) : nil
    }

    static func align(url: URL, modelPath: String, lines: [LyricLine], offset: Double, cache: URL?, progress: @escaping @Sendable (Double) -> Void) throws -> String? {
        // the model loads while the song is being read
        final class Loaded: @unchecked Sendable { var runner: MMSRunner?; var error: Error? }
        let loaded = Loaded()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            do { loaded.runner = try RunnerCache.shared.get(modelPath) } catch { loaded.error = error }
            group.leave()
        }
        let wave = try PCM16k.load(url)
        group.wait()
        defer { RunnerCache.shared.done() }
        if let e = loaded.error { throw e }
        guard let runner = loaded.runner else { throw AlignError("The model couldn't be loaded") }
        guard wave.count > 16000 * 5 else { throw AlignError("The song is too short or can't be read") }
        progress(0.05)
        let seconds = Double(wave.count) / 16000
        var needed: [(Double, Double)] = []
        for i in lines.indices { if let w = window(lines, i, offset: offset, seconds: seconds) { needed.append((max(0, w.0 - 0.3), w.1 + 0.3)) } }
        let em = try runner.emissions(wave, needed: needed, cache: cache) { progress(0.05 + 0.9 * $0) }
        let C = em.classes
        let frames = em.data.count / C
        guard frames > 100 else { throw AlignError("The song is too short") }
        var out = ""
        var prevStamp = 0.0
        var done = 0
        for (i, line) in lines.enumerated() {
            let base = line.time + offset
            var starts: [Double]? = nil
            if let w = window(lines, i, offset: offset, seconds: Double(frames) * frameSeconds) {
                starts = alignLine(line.words.map { $0.text }, spaced: line.text.contains(" "), ws: w.0, we: w.1, em: em.data, classes: C, frames: frames)
            }
            if let s = starts {
                done += 1
                let st = max(prevStamp, min(base, s[0]))
                prevStamp = st
                out += "[\(stamp(st))]"
                for (k, w) in line.words.enumerated() { out += "<\(stamp(max(s[k], st)))>\(w.text)" }
            } else {
                let st = max(prevStamp, base)
                prevStamp = st
                out += "[\(stamp(st))]"
                if line.tagged { for w in line.words { out += "<\(stamp(w.start + offset))>\(w.text)" } }
                else { out += line.text }
            }
            out += "\n"
        }
        progress(1)
        return done > 0 ? out : nil
    }
}
