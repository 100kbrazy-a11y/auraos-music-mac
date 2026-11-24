import Foundation
import AVFoundation
import CVoice

// Precise word timing, made at home and light on purpose: no model to download.
// 1. the song is read as stereo audio; Sources/CVoice keeps the part that is sung (centred, steady, not a drum hit) and finds where the voice is and where its syllables begin
// 2. each lyric line is lined up with that: its words are matched to the syllable starts in the stretch where it is sung
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

/// how many syllables a word has (a good guess for English and the like; one per character for scripts without spaces)
enum Syllables {
    static func count(_ w: String) -> Int {
        let t = w.trimmingCharacters(in: .whitespacesAndNewlines)
        let letters = t.filter { $0.isLetter }
        guard !letters.isEmpty else { return 1 }
        if t.unicodeScalars.contains(where: { $0.value > 0x24F }) { return max(1, letters.count) }
        let vowels = Set("aeiouyáàâäãåéèêëíìîïóòôöõúùûüœæ")
        var groups = 0, inGroup = false
        for ch in letters.lowercased() { if vowels.contains(ch) { if !inGroup { groups += 1; inGroup = true } } else { inGroup = false } }
        let lower = letters.lowercased()
        if groups > 1, lower.hasSuffix("e"), !lower.hasSuffix("le") { groups -= 1 }
        if lower.hasSuffix("ed") && groups > 1 && !(lower.hasSuffix("ted") || lower.hasSuffix("ded")) { groups -= 1 }
        return max(groups, 1)
    }
}

enum Aligner {
    nonisolated static func stamp(_ t: Double) -> String {
        let t = max(0, t)
        let m = Int(t / 60)
        return String(format: "%02d:%05.2f", m, t - Double(m) * 60)
    }

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
                var s = [Double](repeating: 0, count: parts.count)
                var end = 0.0
                let q = strata_voice_align_line(voice, w.0, w.1, base, Int32(parts.count), &syll, &s, &end)
                if q > 0 { starts = s }
            }
            if let s = starts {
                done += 1
                let st = max(prevStamp, min(base, s[0]))
                prevStamp = st
                out += "[\(stamp(st))]"
                for (k, p) in parts.enumerated() { out += "<\(stamp(max(s[k], st)))>\(p)" }
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
