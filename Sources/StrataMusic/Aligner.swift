import Foundation
import AVFoundation
import Accelerate
import OnnxRuntimeBindings

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
        guard len > 0, let tok = CFStringTokenizerCreate(kCFAllocatorDefault, cf, CFRange(location: 0, length: len), kCFStringTokenizerUnitWord, CFLocaleCreate(kCFAllocatorDefault, locale as CFString)) else { return [] }
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
                samples.append(contentsOf: UnsafeBufferPointer(start: c, length: Int(outBuf.frameLength)))
            }
            if status == .error { throw err ?? AlignError("This file's audio can't be converted") }
            if status == .endOfStream { break }
            if outBuf.frameLength == 0 && status != .haveData { break }
        }
        return samples
    }
}

// MARK: - the model

final class MMSRunner {
    private let env: ORTEnv
    private let session: ORTSession
    private let inputName: String
    private let outputName: String

    init(path: String) throws {
        env = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)
        let opts = try ORTSessionOptions()
        let threads = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
        try opts.setIntraOpNumThreads(Int32(threads))
        session = try ORTSession(env: env, modelPath: path, sessionOptions: opts)
        let ins = try session.inputNames(), outs = try session.outputNames()
        guard ins.count == 1, let i = ins.first, let o = outs.first else { throw AlignError("The model isn't the one Strata expects (re-download it from Settings)") }
        inputName = i
        outputName = o
    }

    /// log-probabilities of the model's labels for every 20 ms of the song (frames × classes), computed in overlapping pieces
    func emissions(_ wave: [Float], progress: (Double) -> Void) throws -> (data: [Float], classes: Int) {
        let core = 240_000, ctx = 20_480          // 15 s of audio per piece, plus 1.28 s each side the piece only listens to (both are whole numbers of 320-sample frames)
        let n = wave.count
        var mean: Float = 0, msq: Float = 0
        vDSP_meanv(wave, 1, &mean, vDSP_Length(n))
        vDSP_measqv(wave, 1, &msq, vDSP_Length(n))
        let inv = 1 / sqrt(max(msq - mean * mean, 1e-8))
        var all: [Float] = []
        all.reserveCapacity(n / 320 * 29)
        var classes = 0
        var k = 0
        while k * core < n {
            let coreStart = k * core
            let coreEnd = min(n, coreStart + core)
            let a = max(0, coreStart - ctx), b = min(n, coreEnd + ctx)
            if b - a >= 1600 {
                let chunk = wave[a..<b].map { ($0 - mean) * inv }
                let (logp, frames, c) = try run(chunk)
                classes = c
                let i0 = coreStart / 320 - a / 320
                let i1 = coreEnd == n ? frames : min(frames, coreEnd / 320 - a / 320)
                if i1 > i0 { all.append(contentsOf: logp[(i0 * c)..<(i1 * c)]) }
            }
            k += 1
            progress(min(1, Double(coreEnd) / Double(n)))
        }
        guard classes > 0 else { throw AlignError("The model gave no answer") }
        return (all, classes)
    }

    private func run(_ chunk: [Float]) throws -> ([Float], Int, Int) {
        let n = chunk.count
        guard let data = NSMutableData(length: n * MemoryLayout<Float>.size) else { throw AlignError("Not enough memory") }
        chunk.withUnsafeBytes { data.replaceBytes(in: NSRange(location: 0, length: n * MemoryLayout<Float>.size), withBytes: $0.baseAddress!) }
        let tensor = try ORTValue(tensorData: data, elementType: ORTTensorElementDataType.float, shape: [1, NSNumber(value: n)])
        let outs = try session.run(withInputs: [inputName: tensor], outputNames: [outputName], runOptions: nil)
        guard let o = outs[outputName] else { throw AlignError("The model gave no answer") }
        let dims = try o.tensorTypeAndShapeInfo().shape.map { $0.intValue }
        let raw = try o.tensorData()
        var x = [Float](repeating: 0, count: raw.length / MemoryLayout<Float>.size)
        x.withUnsafeMutableBytes { raw.getBytes($0.baseAddress!, length: raw.length) }
        var frames = 0, c = 0
        switch dims.count {
        case 3: frames = dims[1]; c = dims[2]
        case 2: frames = dims[0]; c = dims[1]
        default: throw AlignError("The model's answer has an unexpected shape")
        }
        guard frames > 0, c > 1, frames * c <= x.count else { throw AlignError("The model's answer has an unexpected shape") }
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
    static func align(url: URL, modelPath: String, lines: [LyricLine], offset: Double, progress: (Double) -> Void) throws -> String? {
        let wave = try PCM16k.load(url)
        guard wave.count > 16000 * 5 else { throw AlignError("The song is too short or can't be read") }
        progress(0.04)
        let runner = try MMSRunner(path: modelPath)
        let em = try runner.emissions(wave) { progress(0.04 + 0.9 * $0) }
        let C = em.classes
        let frames = em.data.count / C
        guard frames > 100 else { throw AlignError("The song is too short") }
        var out = ""
        var prevStamp = 0.0
        var done = 0
        for (i, line) in lines.enumerated() {
            let base = line.time + offset
            var starts: [Double]? = nil
            if !line.text.isEmpty, !line.words.isEmpty {
                let next = i + 1 < lines.count ? lines[i + 1].time + offset : base + 10
                let ws = max(0, base - 0.6)
                var we = max(next + 0.2, base + 1.5)
                let letters = Double(line.text.count)
                we = min(we, base + 4 + letters * 0.25)
                we = min(we, Double(frames) * frameSeconds)
                starts = alignLine(line.words.map { $0.text }, spaced: line.text.contains(" "), ws: ws, we: we, em: em.data, classes: C, frames: frames)
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
