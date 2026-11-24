import XCTest
import CVoice

/// a made-up song: four sung notes at the start of each of six lines, a wide pad underneath
final class VoiceTests: XCTestCase {
    private func song() -> (analysis: OpaquePointer, lineStarts: [Double]) {
        let sr = 22050, n = sr * 40
        var l = [Float](repeating: 0, count: n), r = [Float](repeating: 0, count: n)
        var seed: UInt32 = 5
        func rnd() -> Double { seed = seed &* 1664525 &+ 1013904223; return Double((seed >> 8) & 0xFFFF) / 65536 }
        var starts: [Double] = []
        for line in 0..<6 {
            let begin = 3 + 5.5 * Double(line)
            starts.append(begin)
            var t = begin
            for _ in 0..<4 {
                let f0 = 180 + 60 * rnd()
                for i in 0..<Int(0.4 * Double(sr)) {
                    let idx = Int(t * Double(sr)) + i
                    let x = Double(i) / (0.4 * Double(sr))
                    let env = x < 0.1 ? x / 0.1 : (x > 0.7 ? (1 - x) / 0.3 : 1)
                    var v = 0.0
                    for h in 1...8 { v += sin(2 * Double.pi * f0 * Double(h) * Double(i) / Double(sr)) / Double(h) }
                    l[idx] += Float(0.25 * env * v); r[idx] += Float(0.25 * env * v)
                }
                t += 0.55
            }
        }
        for i in 0..<n {
            var p = 0.0
            for h in 0..<4 { p += sin(2 * Double.pi * (220 + 55 * Double(h)) * Double(i) / Double(sr)) }
            l[i] += Float(0.05 * p); r[i] -= Float(0.045 * p)
        }
        let a = l.withUnsafeBufferPointer { lp in r.withUnsafeBufferPointer { rp in strata_voice_analyze(lp.baseAddress, rp.baseAddress, Int64(n), Int32(sr)) } }
        return (a!, starts)
    }

    func testLyricsThatAreOffAreFound() {
        let (a, starts) = song()
        defer { strata_voice_free(a) }
        for off in [0.0, 0.5, -0.4] {
            let bases = starts.map { $0 + off }
            var used: Int32 = 0
            let residual = bases.withUnsafeBufferPointer { strata_voice_residual(a, Int32($0.count), $0.baseAddress, &used) }
            XCTAssertEqual(residual, -off, accuracy: 0.06, "lyrics \(off) s off")
            XCTAssertEqual(used, 6)
        }
    }

    func testWordsFollowTheNotes() {
        let (a, starts) = song()
        defer { strata_voice_free(a) }
        // "one two three four", one note each, the line starting where the lyrics say
        var syll: [Int32] = [1, 1, 1, 1], quick: [Int32] = [0, 0, 0, 0]
        var s = [Double](repeating: 0, count: 4), e = [Double](repeating: 0, count: 4)
        var end = 0.0
        let q = strata_voice_align_line(a, starts[1] - 0.15, starts[1] + 4, 0, starts[1], 0.2, 4, &syll, &quick, &s, &e, &end)
        XCTAssertEqual(q, 2)
        for k in 0..<4 { XCTAssertEqual(s[k], starts[1] + 0.55 * Double(k), accuracy: 0.08) }
        XCTAssertLessThan(e[1], s[2])
    }

    func testSyllableCounter() {
        XCTAssertEqual(strata_voice_syllables("everyone"), 3)
        XCTAssertEqual(strata_voice_syllables("eh"), 1)
    }
}
