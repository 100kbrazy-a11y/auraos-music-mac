import Foundation
import AVFoundation
import Accelerate

/// What one pass over a song's audio finds out: roughly how loud it is (for volume levelling) and a picture of its spectrum over time (for the visualizer).
struct SongAnalysis: Codable {
    var db: Float                // loudness estimate: gated average level, in dB below full scale
    var peak: Float              // loudest sample, 0...1
    var fps: Float               // spectrum frames per second
    var bandCount: Int
    var bands: Data              // frames × bandCount values, 0...255

    func frame(at seconds: Double) -> [Float] {
        let frames = bands.count / max(1, bandCount)
        guard frames > 0 else { return [] }
        let f = max(0, min(frames - 1, Int(seconds * Double(fps))))
        let start = f * bandCount
        return bands[start..<(start + bandCount)].map { Float($0) / 255 }
    }
}

enum Analyzer {
    static let bandCount = 32
    static let fps = 20.0
    static let targetDb: Float = -17

    /// the gain (in dB) that brings a song to the common level. The standard player can only turn volume down; the enhanced engine can also lift a quiet song a little.
    static func gain(_ a: SongAnalysis, canBoost: Bool) -> Float {
        var g = targetDb - a.db
        g = min(g, canBoost ? 6 : 0)
        g = max(g, -12)
        // never lift the loudest sample past full scale
        let peakDb = 20 * log10(max(a.peak, 0.000_001))
        if g > 0 && g + peakDb > -0.5 { g = max(0, -0.5 - peakDb) }
        return g
    }

    nonisolated static func analyze(_ url: URL) -> SongAnalysis? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let fmt = file.processingFormat
        let sr = fmt.sampleRate
        let ch = Int(fmt.channelCount)
        guard sr > 8000, ch > 0 else { return nil }
        let hop = max(256, Int(sr / fps))
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(hop)) else { return nil }

        let n = 2048, log2n = vDSP_Length(11)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        // band edges, spread evenly on a log scale from 40 Hz to 16 kHz
        let binHz = sr / Double(n)
        var edges: [Int] = []
        for i in 0...bandCount {
            let f = 40.0 * pow(16000.0 / 40.0, Double(i) / Double(bandCount))
            edges.append(max(1, min(n / 2 - 1, Int(f / binHz))))
        }

        var tail = [Float](repeating: 0, count: n)
        var out = Data()
        var blockEnergy: [Double] = []
        var acc = 0.0, accN = 0
        var peak: Float = 0
        var mono = [Float](repeating: 0, count: hop)
        var real = [Float](repeating: 0, count: n / 2), imag = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        var windowed = [Float](repeating: 0, count: n)

        while file.framePosition < file.length {
            buf.frameLength = 0
            do { try file.read(into: buf, frameCount: AVAudioFrameCount(hop)) } catch { break }
            let len = Int(buf.frameLength)
            if len == 0 { break }
            guard let data = buf.floatChannelData else { return nil }
            for i in 0..<len {
                var s: Float = 0
                for c in 0..<ch { s += data[c][i] }
                s /= Float(ch)
                mono[i] = s
                let a = abs(s); if a > peak { peak = a }
            }
            // loudness: average energy of 400 ms blocks
            var e = 0.0
            for i in 0..<len { e += Double(mono[i]) * Double(mono[i]) }
            acc += e; accN += len
            if accN >= Int(sr * 0.4) { blockEnergy.append(acc / Double(accN)); acc = 0; accN = 0 }

            // spectrum of the last 2048 samples
            if len >= n { tail = Array(mono[(len - n)..<len]) }
            else { tail.removeFirst(len); tail.append(contentsOf: mono[0..<len]) }
            vDSP_vmul(tail, 1, window, 1, &windowed, 1, vDSP_Length(n))
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { wp in
                        wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { c in
                            vDSP_ctoz(c, 2, &split, 1, vDSP_Length(n / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                    vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(n / 2))
                }
            }
            for b in 0..<bandCount {
                let lo = edges[b], hi = max(edges[b] + 1, edges[b + 1])
                var m: Float = 0
                for k in lo..<min(hi, n / 2) { m = max(m, mags[k]) }
                let db = 20 * log10(max(m / Float(n), 1e-7))
                let v = max(0, min(1, (db + 72) / 72))
                out.append(UInt8(v * 255))
            }
        }
        if accN > 0 { blockEnergy.append(acc / Double(accN)) }

        // gating, as loudness meters do: ignore silence, then ignore everything far below the rest
        let audible = blockEnergy.filter { $0 > 1e-5 }
        var db: Float = -30
        if !audible.isEmpty {
            let mean1 = audible.reduce(0, +) / Double(audible.count)
            let floor = mean1 * 0.1
            let kept = audible.filter { $0 >= floor }
            let mean2 = kept.isEmpty ? mean1 : kept.reduce(0, +) / Double(kept.count)
            db = Float(10 * log10(max(mean2, 1e-9)))
        }
        return SongAnalysis(db: db, peak: peak, fps: Float(sr / Double(hop)), bandCount: bandCount, bands: out)
    }
}

/// keeps the results (in memory and on disk), so a song is only ever read once
@MainActor
final class Analysis {
    static let shared = Analysis()
    private var memory: [String: SongAnalysis] = [:]
    private var running: [String: Task<SongAnalysis?, Never>] = [:]

    private func file(_ s: Song) -> URL {
        let d = Disk.dir.appendingPathComponent("analysis", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("\(s.id).json")
    }

    func cached(_ s: Song) -> SongAnalysis? { memory[s.id] }

    func load(_ s: Song, url: URL) async -> SongAnalysis? {
        if let m = memory[s.id] { return m }
        if let t = running[s.id] { return await t.value }
        let f = file(s)
        let t = Task.detached(priority: .utility) { () -> SongAnalysis? in
            if let d = try? Data(contentsOf: f), let a = try? JSONDecoder().decode(SongAnalysis.self, from: d), a.bandCount == Analyzer.bandCount { return a }
            guard let a = Analyzer.analyze(url) else { return nil }
            if let d = try? JSONEncoder().encode(a) { try? d.write(to: f, options: .atomic) }
            return a
        }
        running[s.id] = t
        let a = await t.value
        running[s.id] = nil
        if let a = a { memory[s.id] = a; if memory.count > 40 { memory.removeValue(forKey: memory.keys.first(where: { $0 != s.id }) ?? "") } }
        return a
    }
}
