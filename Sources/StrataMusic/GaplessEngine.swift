import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

/// The "Enhanced" playback engine: two player nodes on an AVAudioEngine. The next song is opened ahead of time and started at the
/// exact moment the current one ends (gapless), or a little earlier with a volume cross-over (crossfade). It also carries the
/// 10-band equaliser and the speed control. Everything is optional: the Standard engine (AVPlayer) stays the default.
@MainActor
final class GaplessEngine {
    private let engine = AVAudioEngine()
    private let bus = AVAudioMixerNode()
    let eq = AVAudioUnitEQ(numberOfBands: 10)
    let pitch = AVAudioUnitTimePitch()
    private let nodes = [AVAudioPlayerNode(), AVAudioPlayerNode()]

    private struct Voice {
        var file: AVAudioFile
        var node: Int
        var offset: Double          // where in the song this node started (after a seek)
        var url: URL
        var gen: Int
    }
    private var cur: Voice?
    private var next: Voice?
    private var startedNext = false
    private var transitionStart: Date?
    private var transitionLen = 0.0
    private var timer: Timer?
    private var gen = 0
    private(set) var playing = false

    /// the Player listens to these
    var onTick: ((Double) -> Void)?
    var onEnd: (() -> Void)?                 // the last song ran out (nothing was queued behind it)
    var onAdvance: (() -> Void)?             // the preloaded song took over
    var crossfade: Double = 0               // seconds

    static let freqs: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let presets: [(String, [Float])] = [
        ("Flat", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ("Bass Boost", [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        ("Vocal", [-2, -1, 0, 2, 4, 4, 3, 1, 0, -1]),
        ("Treble", [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]),
        ("Loudness", [5, 3, 0, -1, -1, 0, 0, 2, 4, 5]),
        ("Late Night", [3, 2, 1, 0, -1, -2, -2, -3, -4, -5]),
    ]

    init() {
        for (i, b) in eq.bands.enumerated() { b.filterType = .parametric; b.frequency = Self.freqs[i]; b.bandwidth = 1; b.gain = 0; b.bypass = false }
        engine.attach(bus); engine.attach(eq); engine.attach(pitch)
        for n in nodes { engine.attach(n) }
        let std = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)
        engine.connect(bus, to: eq, format: std)
        engine.connect(eq, to: pitch, format: std)
        engine.connect(pitch, to: engine.mainMixerNode, format: std)
    }

    // MARK: settings

    func setGains(_ g: [Float]) { for (i, b) in eq.bands.enumerated() where i < g.count { b.gain = g[i] } }
    func setRate(_ r: Float) { pitch.rate = max(0.5, min(2, r)) }
    func setVolume(_ v: Float) { engine.mainMixerNode.outputVolume = v }
    /// volume levelling: lifts or lowers the whole song by [db]
    func setLevel(_ db: Float) { eq.globalGain = max(-24, min(24, db)) }

    /// plays through one particular output (nil = the Mac's default). Returns false when the engine wouldn't take it.
    @discardableResult
    func setOutputDevice(_ id: AudioDeviceID?) -> Bool {
        guard let unit = engine.outputNode.audioUnit else { return false }
        var dev: AudioDeviceID
        if let id = id { dev = id } else {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            dev = 0
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr else { return false }
        }
        let was = engine.isRunning
        if was { engine.stop() }
        let r = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        if was { engine.prepare(); try? engine.start() }
        return r == noErr
    }

    // MARK: loading and moving

    private func ensureRunning() {
        if !engine.isRunning { engine.prepare(); try? engine.start() }
    }

    private func makeVoice(_ url: URL, node: Int) throws -> Voice {
        let f = try AVAudioFile(forReading: url)
        let n = nodes[node]
        n.stop()
        engine.disconnectNodeOutput(n)
        engine.connect(n, to: bus, format: f.processingFormat)
        n.volume = 1
        gen += 1
        return Voice(file: f, node: node, offset: 0, url: url, gen: gen)
    }

    /// opens [url] as the current song (replacing whatever was current)
    func load(_ url: URL, autoplay: Bool) throws {
        stopAll()
        var v = try makeVoice(url, node: 0)
        v.offset = 0
        cur = v
        nodes[0].scheduleFile(v.file, at: nil, completionHandler: nil)
        ensureRunning()
        if autoplay { nodes[0].play(); playing = true } else { playing = false }
        startTimer()
    }

    /// opens the song that follows, silently, on the other node
    func preload(_ url: URL?) {
        if let n = next { nodes[n.node].stop(); next = nil }
        startedNext = false
        guard let url = url, let c = cur else { return }
        guard let v = try? makeVoice(url, node: 1 - c.node) else { return }
        nodes[v.node].scheduleFile(v.file, at: nil, completionHandler: nil)
        next = v
    }

    func play() { guard cur != nil else { return }; ensureRunning(); if let c = cur { nodes[c.node].play() }; if startedNext, let n = next { nodes[n.node].play() }; playing = true }
    func pause() { for n in nodes { n.pause() }; playing = false }

    func seek(_ t: Double) {
        guard var c = cur else { return }
        let sr = c.file.processingFormat.sampleRate
        let frame = AVAudioFramePosition(max(0, min(t, Double(c.file.length) / sr - 0.05)) * sr)
        let n = nodes[c.node]
        let was = playing
        n.stop()
        if startedNext, let nx = next { nodes[nx.node].stop(); startedNext = false; transitionStart = nil; nodes[nx.node].volume = 1
            // the next song starts over from the top later
            nodes[nx.node].scheduleFile(nx.file, at: nil, completionHandler: nil) }
        n.volume = 1
        n.scheduleSegment(c.file, startingFrame: frame, frameCount: AVAudioFrameCount(max(1, c.file.length - frame)), at: nil, completionHandler: nil)
        c.offset = Double(frame) / sr
        cur = c
        if was { n.play() }
    }

    func stopAll() {
        timer?.invalidate(); timer = nil
        for n in nodes { n.stop() }
        cur = nil; next = nil; startedNext = false; transitionStart = nil; playing = false
    }

    // MARK: time

    private func position(of v: Voice) -> Double {
        let n = nodes[v.node]
        guard let rt = n.lastRenderTime, let pt = n.playerTime(forNodeTime: rt) else { return v.offset }
        return v.offset + max(0, Double(pt.sampleTime) / pt.sampleRate)
    }

    var position: Double { cur.map(position(of:)) ?? 0 }
    var duration: Double { cur.map { Double($0.file.length) / $0.file.processingFormat.sampleRate } ?? 0 }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let c = cur else { return }
        let pos = position(of: c)
        let dur = Double(c.file.length) / c.file.processingFormat.sampleRate
        let remaining = dur - pos
        onTick?(pos)
        guard playing else { return }

        // start the next song at the right moment: exactly at the end (gapless), or earlier for a crossfade
        if let nx = next, !startedNext, remaining <= max(crossfade, 0) + 0.12 {
            startedNext = true
            let lead = max(0, remaining - crossfade)                       // seconds until the next song should begin
            let nn = nodes[nx.node]
            if let rt = nodes[c.node].lastRenderTime, lead > 0 {
                let host = rt.hostTime + AVAudioTime.hostTime(forSeconds: lead)
                nn.play(at: AVAudioTime(hostTime: host))
            } else { nn.play() }
            transitionLen = crossfade
            transitionStart = Date().addingTimeInterval(lead)
            if crossfade > 0 { nn.volume = 0 }
        }
        // the cross-over volumes
        if let t0 = transitionStart, let nx = next, crossfade > 0 {
            let p = max(0, min(1, Date().timeIntervalSince(t0) / max(0.1, transitionLen)))
            nodes[nx.node].volume = Float(sin(p * .pi / 2))
            nodes[c.node].volume = Float(cos(p * .pi / 2))
        }
        // the current song has run out
        if remaining <= 0.02 || (!nodes[c.node].isPlaying && remaining < 0.3) {
            if startedNext, let nx = next {
                nodes[c.node].stop(); nodes[c.node].volume = 1
                nodes[nx.node].volume = 1
                cur = Voice(file: nx.file, node: nx.node, offset: 0, url: nx.url, gen: nx.gen)
                next = nil; startedNext = false; transitionStart = nil
                onAdvance?()
            } else {
                nodes[c.node].stop(); playing = false
                onEnd?()
            }
        }
    }
}
