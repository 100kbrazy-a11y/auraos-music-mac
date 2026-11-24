import Foundation
import AVFoundation
import CVoice

// Precise word timing, made at home and light on purpose: no model to download.
// 1. the song is read as stereo audio; Sources/CVoice keeps the part that is sung (centred, steady, not a drum hit) and finds where the voice is and where its syllables begin
// 2. each lyric line is lined up with that: its words are matched to the syllable starts in the stretch where it is sung
// The lyrics' own line times are the authority: a line never starts before its stamp or runs past the next line's, so words can't be mixed up between lines. The audio only decides where the words fall inside the line's own slot.
// The words' times are written as an enhanced .lrc (a time before each word), which other Strata versions can read.

struct AlignError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// the whole song as 22.05 kHz stereo floats
enum PCM22k {
    static let rate = 22050

    static func load(_ url: URL) throws -> (left: [Float], right: [Float]) {
        let file = try AVAudioFile(forReading: url)
        let inFmt = file.processingFormat
        guard inFmt.sampleRate > 0, file.length > 0 else { throw AlignError("This file's audio can't be read") }
        guard Double(file.length) / inFmt.sampleRate < 15 * 60 else { throw AlignError("This song is too long to analyse (over 15 minutes)") }
        guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 2, interleaved: false),
              let conv = AVAudioConverter(from: inFmt, to: outFmt) else { throw AlignError("This file's audio can't be read") }
        let inCap: AVAudioFrameCount = 32768
        let outCap = AVAudioFrameCount(Double(inCap) * Double(rate) / inFmt.sampleRate) + 2048
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: inCap),
              let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap) else { throw AlignError("Not enough memory to read the song") }
        let expected = Int(Double(file.length) / inFmt.sampleRate * Double(rate)) + rate
        var left: [Float] = [], right: [Float] = []
        left.reserveCapacity(expected); right.reserveCapacity(expected)
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
            if let ch = outBuf.floatChannelData, outBuf.frameLength > 0 {
                let n = Int(outBuf.frameLength)
                left.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: n))
                right.append(contentsOf: UnsafeBufferPointer(start: ch[outBuf.format.channelCount > 1 ? 1 : 0], count: n))
            }
            if status == .error { throw err ?? AlignError("This file's audio can't be converted") }
            if status == .endOfStream { break }
            if outBuf.frameLength == 0 && status != .haveData { break }
        }
        return (left, right)
    }
}

/// how many syllables a word has, and which words are sung fast and short
enum Syllables {
    /// English-like words go through the C counter (silent e, "-ing", "-ed", a table of oddities like "everyone"); scripts without spaces get one per character
    static func count(_ w: String) -> Int {
        let t = w.trimmingCharacters(in: .whitespacesAndNewlines)
        let letters = t.filter { $0.isLetter }
        guard !letters.isEmpty else { return 1 }
        let plain = t.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let ascii = plain.unicodeScalars.filter { $0.isASCII && CharacterSet.letters.contains($0) }.count
        if ascii == 0 || plain.unicodeScalars.contains(where: { $0.value > 0x24F && CharacterSet.letters.contains($0) }) { return max(1, letters.count) }
        return Int(strata_voice_syllables(plain))
    }

    /// what a word is, for spotting a repeat
    static func key(_ w: String) -> String {
        w.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).filter { $0.isLetter }
    }

    /// 1 for a word that repeats the one before or after it ("eh eh", "la la la", "I I I"): those are sung quickly, so they get a shorter share of the line
    static func quick(_ parts: [String]) -> [Int32] {
        let k = parts.map(key)
        return (0..<k.count).map { (i: Int) -> Int32 in
            guard !k[i].isEmpty else { return 0 }
            return (i > 0 && k[i] == k[i - 1]) || (i + 1 < k.count && k[i] == k[i + 1]) ? 1 : 0
        }
    }
}

enum Aligner {
    nonisolated static func stamp(_ t: Double) -> String {
        let t = max(0, t)
        let m = Int(t / 60)
        return String(format: "%02d:%05.2f", m, t - Double(m) * 60)
    }

    static func isAdlib(_ s: String) -> Bool { let t = s.trimmingCharacters(in: .whitespaces); return t.count > 2 && t.hasPrefix("(") && t.hasSuffix(")") }

    /// the slot a line has in the lyrics (audio time): from its stamp to the next line's. A "(ad-lib)" line sung over the top doesn't end the line before it.
    static func slot(_ lines: [LyricLine], _ i: Int, offset: Double) -> (start: Double, end: Double) {
        let line = lines[i]
        let base = line.time + offset
        var k = i + 1
        if !isAdlib(line.text) { while k < lines.count, isAdlib(lines[k].text) { k += 1 } }
        let end = k < lines.count ? lines[k].time + offset : base + min(8, 1.5 + Double(line.text.count) * 0.12)
        return (base, max(end, base + 0.4))
    }

    /// the stretch of the song searched for a line's singing: its own slot (a hair early, in case the stamp is a touch late)
    static func window(_ lines: [LyricLine], _ i: Int, offset: Double, seconds: Double) -> (Double, Double)? {
        let line = lines[i]
        guard !line.text.isEmpty, !line.words.isEmpty else { return nil }
        let slot = slot(lines, i, offset: offset)
        let ws = max(0, slot.start - 0.15)
        let we = min(slot.end, seconds)
        return we - ws > 0.4 ? (ws, we) : nil
    }

    /// the pieces of a line that get their own time: its words (or, for a line written without spaces in Latin letters, the line as a whole)
    static func pieces(_ line: LyricLine) -> [String] {
        if !line.text.contains(" "), line.text.unicodeScalars.allSatisfy({ $0.value <= 0x24F }) { return [line.text] }
        return line.words.map { $0.text }
    }

    /// aligns a whole song. The result is an enhanced .lrc (a time before each word) in the song's own audio time, or nil if no line could be lined up.
    static func align(url: URL, lines: [LyricLine], offset: Double, progress: @escaping @Sendable (Double) -> Void) throws -> String? {
        let pcm = try PCM22k.load(url)
        guard pcm.left.count > PCM22k.rate * 8 else { throw AlignError("The song is too short or can't be read") }
        progress(0.35)
        let seconds = Double(pcm.left.count) / Double(PCM22k.rate)
        let voice: OpaquePointer? = pcm.left.withUnsafeBufferPointer { l in
            pcm.right.withUnsafeBufferPointer { r in strata_voice_analyze(l.baseAddress, r.baseAddress, Int64(l.count), Int32(PCM22k.rate)) }
        }
        guard let voice else { throw AlignError("Couldn't make sense of this song's audio") }
        defer { strata_voice_free(voice) }
        progress(0.7)
        var out = ""
        var prevStamp = 0.0
        var done = 0
        for (i, line) in lines.enumerated() {
            let base = line.time + offset
            let parts = pieces(line)
            var starts: [Double]? = nil
            if let w = window(lines, i, offset: offset, seconds: seconds), !parts.isEmpty {
                var syll = parts.map { Int32(Syllables.count($0)) }
                var quick = Syllables.quick(parts)
                var s = [Double](repeating: 0, count: parts.count)
                var end = 0.0
                let q = strata_voice_align_line(voice, w.0, w.1, base, Int32(parts.count), &syll, &quick, &s, &end)
                if q > 0 { starts = s }
            }
            if var s = starts {
                // inside the line's own slot, and never before the one before it
                let slot = slot(lines, i, offset: offset)
                let lastOK = max(slot.start, slot.end - 0.12)
                let first = max(slot.start, prevStamp)
                var prev = first
                for k in 0..<s.count { s[k] = min(max(s[k] + 0.03, prev), lastOK); prev = s[k] }
                done += 1
                prevStamp = first
                out += "[\(stamp(first))]"
                for (k, p) in parts.enumerated() { out += "<\(stamp(s[k]))>\(p)" }
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
