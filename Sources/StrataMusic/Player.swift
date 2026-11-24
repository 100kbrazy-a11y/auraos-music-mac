import Foundation
import AVFoundation
import MediaPlayer
import SwiftUI

/// the play position lives on its own object: only the views that show it redraw four times a second, not the whole app
final class Clock: ObservableObject {
    @Published var position: Double = 0
}

@MainActor
final class Player: ObservableObject {
    static let shared = Player()

    @Published private(set) var queue: [Song] = []
    @Published private(set) var index = 0
    @Published private(set) var current: Song?
    @Published private(set) var isPlaying = false
    @Published private(set) var accent: Color = Theme.accent
    @Published var shuffle = false { didSet { reshuffle() } }
    @Published var repeatMode = 0                      // 0 off, 1 all, 2 one
    /// the volume lives in its own small object, so dragging the slider redraws the slider and nothing else
    let vol = VolumeModel()
    var volume: Float { get { vol.value } set { vol.value = newValue; setOutVolume(newValue) } }
    /// 0.5x to 2x
    @Published var speed: Float = 1 { didSet { avp.defaultRate = speed; if isPlaying && !usingGE { avp.rate = speed }; ge?.setRate(speed); pushNowPlaying() } }
    @Published private(set) var decoding = false
    /// the sleep timer: stops the music at [sleepEnd], or when the current song ends
    @Published private(set) var sleepEnd: Date?
    @Published private(set) var sleepAtSongEnd = false
    let clock = Clock()
    private var sleepTask: Task<Void, Never>?

    private let avp = AVPlayer()
    private var ge: GaplessEngine?
    private var usingGE = false
    private var counted = false
    private var lastSaved = 0
    private var baseQueue: [Song] = []
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var lastNowPlayingPush = 0.0

    var duration: Double { current?.duration ?? 0 }

    /// the accent setting changed
    func refreshAccent() { updateAccent(current) }

    /// the colour comes from the cover; reading it is done away from the main thread so changing songs never stutters
    private func updateAccent(_ s: Song?) {
        if UserDefaults.standard.string(forKey: "accentMode") == "fixed" { accent = Look.accent(for: s); return }
        if let c = Covers.cachedAccent(s) { accent = c; return }
        Task { let c = await Covers.accentAsync(s); if current?.id == s?.id { accent = c } }
    }

    private init() {
        timeObserver = avp.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            let s = t.seconds
            Task { @MainActor in
                guard let self = self, s.isFinite, !self.usingGE else { return }
                self.tickPosition(s)
            }
        }
        avp.audioOutputDeviceUniqueID = AudioOutputs.shared.activeDevice?.uid
        setupRemote()
    }

    /// both engines report the play position here
    private func tickPosition(_ s: Double) {
        clock.position = s
        if Int(s) / 5 != lastSaved { lastSaved = Int(s) / 5; UserDefaults.standard.set(s, forKey: "lastPosition") }
        if !counted, let c = current, s > min(30, max(5, c.duration * 0.5)) { counted = true; Library.main?.recordPlay(c.id) }
    }

    /// at launch: the song that was playing last time, paused where it stopped
    func restoreLast(_ lib: Library) {
        guard current == nil, let id = UserDefaults.standard.string(forKey: "lastSong"), let s = lib.byID[id] else { return }
        baseQueue = [s]; queue = [s]; index = 0
        load(s, autoplay: false)
        let pos = UserDefaults.standard.double(forKey: "lastPosition")
        if pos > 1 && pos < s.duration - 2 { seek(to: pos) }
    }

    // MARK: queue

    func play(_ song: Song, in list: [Song]) {
        baseQueue = list.isEmpty ? [song] : list
        if shuffle {
            var rest = baseQueue.filter { $0.id != song.id }; rest.shuffle()
            queue = [song] + rest; index = 0
        } else {
            queue = baseQueue; index = queue.firstIndex(where: { $0.id == song.id }) ?? 0
        }
        load(queue[index], autoplay: true)
    }

    func playAll(_ list: [Song], shuffled: Bool) {
        guard !list.isEmpty else { return }
        shuffle = shuffled
        let first = shuffled ? list.randomElement()! : list[0]
        play(first, in: list)
    }

    func playNext(_ s: Song) { if queue.isEmpty { play(s, in: [s]) } else { queue.insert(s, at: min(index + 1, queue.count)); refreshPreload() } }
    func enqueue(_ s: Song) { if queue.isEmpty { play(s, in: [s]) } else { queue.append(s); refreshPreload() } }

    /// jump to a song that is already in the queue
    func jump(to i: Int) { guard queue.indices.contains(i) else { return }; index = i; load(queue[i], autoplay: true) }

    func removeFromQueue(_ i: Int) {
        guard queue.indices.contains(i), i != index else { return }
        let gone = queue.remove(at: i)
        if i < index { index -= 1 }
        if let b = baseQueue.firstIndex(where: { $0.id == gone.id }) { baseQueue.remove(at: b) }
        refreshPreload()
    }

    func clearUpNext() { if queue.indices.contains(index) { queue = Array(queue[0...index]); refreshPreload() } }

    // MARK: sleep timer

    func sleep(minutes: Int) {
        cancelSleep()
        sleepEnd = Date().addingTimeInterval(Double(minutes) * 60)
        sleepTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
            if !Task.isCancelled { await self?.fadeOutAndPause() }
        }
    }
    func sleepAfterThisSong() { cancelSleep(); sleepAtSongEnd = true }
    func cancelSleep() { sleepTask?.cancel(); sleepTask = nil; sleepEnd = nil; sleepAtSongEnd = false }

    private func fadeOutAndPause() async {
        sleepEnd = nil
        let start = volume
        for i in stride(from: 9, through: 0, by: -1) { setOutVolume(start * Float(i) / 10); try? await Task.sleep(nanoseconds: 250_000_000) }
        if isPlaying { togglePlay() }
        setOutVolume(start)
    }

    private func reshuffle() {
        guard let cur = current, !baseQueue.isEmpty else { return }
        if shuffle {
            var rest = baseQueue.filter { $0.id != cur.id }; rest.shuffle()
            queue = [cur] + rest; index = 0
        } else {
            queue = baseQueue; index = queue.firstIndex(where: { $0.id == cur.id }) ?? 0
        }
        refreshPreload()
    }

    // MARK: transport

    private func setOutVolume(_ v: Float) {
        // the standard player can only be turned down, so a positive levelling gain only applies on the enhanced engine
        avp.volume = v * powf(10, min(0, levelDb) / 20)
        ge?.setVolume(v); ge?.setLevel(levelDb)
    }

    // MARK: volume levelling and the visualizer

    /// the analysis of the song that is playing (its spectrum drives the visualizer)
    @Published private(set) var spectrum: SongAnalysis?
    private(set) var levelDb: Float = 0

    /// Makes the level ready before the song starts, so it never begins loud and then drops: a song that hasn't been measured yet
    /// is measured first (this takes a moment, and playback gives up waiting after a second and a half).
    private func prepareLevel(_ s: Song, url: URL) async {
        let d = UserDefaults.standard
        let level = d.object(forKey: "levelVolume") as? Bool ?? true
        let viz = (d.string(forKey: "visualizer") ?? "bars") != "off"
        guard level || viz else { spectrum = nil; levelDb = 0; setOutVolume(volume); return }
        if let a = Analysis.shared.cached(s) { adopt(a, level: level); return }
        spectrum = nil; levelDb = 0; setOutVolume(volume)
        if level {
            let a: SongAnalysis? = await withTaskGroup(of: SongAnalysis?.self) { g in
                g.addTask { await Analysis.shared.load(s, url: url) }
                g.addTask { try? await Task.sleep(nanoseconds: 1_500_000_000); return nil }
                let first = await g.next()
                g.cancelAll()
                return first ?? nil
            }
            guard current?.id == s.id else { return }
            if let a = a { adopt(a, level: level); return }
        }
        // too slow (or only the visualizer is on): carry on and adopt the result when it arrives
        Task {
            let a = await Analysis.shared.load(s, url: url)
            if current?.id == s.id, let a = a { adopt(a, level: level) }
        }
    }

    private var enhancedChosen: Bool { UserDefaults.standard.bool(forKey: "enhancedEngine") }

    private func adopt(_ a: SongAnalysis, level: Bool) {
        spectrum = a
        levelDb = level ? Analyzer.gain(a, canBoost: enhancedChosen) : 0
        setOutVolume(volume)
    }

    /// the levelling or visualizer setting changed: apply it to the song that is playing
    func refreshAnalysis() {
        guard let s = current else { return }
        Task { await prepareLevel(s, url: playableURL(s) ?? s.url) }
    }

    /// reads the next song's analysis ahead of time, so there is no jump in volume when it starts
    private func warmAnalysis() {
        guard let i = nextIndex() else { return }
        let s = queue[i]
        guard Analysis.shared.cached(s) == nil, let u = playableURL(s) else { return }
        Task { _ = await Analysis.shared.load(s, url: u) }
    }

    /// the output chosen in the player or in settings
    func applyOutputDevice() {
        let out = AudioOutputs.shared
        let dev = out.activeDevice
        avp.audioOutputDeviceUniqueID = dev?.uid
        if let g = ge {
            let ok = g.setOutputDevice(dev?.deviceID)
            if !ok { EngineLog.shared.add("Couldn't switch the enhanced engine's output") }
            if ok, usingGE, let s = current, isPlaying {
                // the engine restarts on the new device; carry on from where the song was
                let pos = clock.position
                Task { await start(s, autoplay: true); seek(to: pos) }
            }
        }
    }
    private func engPlay() { if usingGE { ge?.play() } else { avp.play(); if speed != 1 { avp.rate = speed } } }
    private func engPause() { if usingGE { ge?.pause() } else { avp.pause() } }

    private func geEngine() -> GaplessEngine {
        if let g = ge { return g }
        let g = GaplessEngine()
        g.onTick = { [weak self] s in self?.tickPosition(s) }
        g.onEnd = { [weak self] in self?.ended() }
        g.onAdvance = { [weak self] in self?.advanceGapless() }
        ge = g
        g.setVolume(volume); g.setRate(speed); g.setLevel(levelDb)
        if let d = AudioOutputs.shared.activeDevice { g.setOutputDevice(d.deviceID) }
        applyAudioSettings()
        return g
    }

    /// equaliser, crossfade: read from the settings (also called when they change)
    func applyAudioSettings() {
        guard let g = ge else { return }
        let d = UserDefaults.standard
        let name = d.string(forKey: "eqPreset") ?? "Flat"
        if name == "Custom", let arr = d.array(forKey: "eqGains") as? [Double], arr.count == 10 { g.setGains(arr.map { Float($0) }) }
        else { g.setGains(GaplessEngine.presets.first { $0.0 == name }?.1 ?? Array(repeating: 0, count: 10)) }
        g.crossfade = d.double(forKey: "crossfade")
        refreshPreload()
    }

    /// the song that follows the current one, honouring repeat
    private func nextIndex() -> Int? {
        guard !queue.isEmpty else { return nil }
        if repeatMode == 2 { return index }
        if index + 1 < queue.count { return index + 1 }
        if repeatMode == 1 { return 0 }
        return nil
    }

    private func playableURL(_ s: Song) -> URL? {
        if OggOpus.isOpus(s.url) { let c = Disk.decodedURL(s); return FileManager.default.fileExists(atPath: c.path) ? c : nil }
        return s.url
    }

    /// lets the enhanced engine open the next song ahead of time
    private func refreshPreload() {
        warmAnalysis()
        guard usingGE, let g = ge else { return }
        guard let i = nextIndex(), let u = playableURL(queue[i]) else { g.preload(nil); return }
        let same = current.map { $0.albumKey == queue[i].albumKey && !$0.album.isEmpty } ?? false
        g.crossfade = same ? 0 : UserDefaults.standard.double(forKey: "crossfade")
        g.preload(u)
    }

    /// the enhanced engine already switched to the preloaded song
    private func advanceGapless() {
        guard let i = nextIndex() else { return }
        index = i
        let s = queue[i]
        current = s; counted = false
        UserDefaults.standard.set(s.id, forKey: "lastSong")
        updateAccent(s)
        clock.position = 0
        if let a = Analysis.shared.cached(s) { adopt(a, level: UserDefaults.standard.object(forKey: "levelVolume") as? Bool ?? true) } else { spectrum = nil; levelDb = 0; setOutVolume(volume) }
        pushNowPlaying(); pushDiscord()
        refreshPreload()
    }

    private func load(_ s: Song, autoplay: Bool) {
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        current = s; counted = false
        UserDefaults.standard.set(s.id, forKey: "lastSong")
        updateAccent(s)
        clock.position = 0
        isPlaying = autoplay
        pushNowPlaying(); pushDiscord()
        Task { await start(s, autoplay: autoplay) }
    }

    /// opens the file (Opus files are decoded once first) on whichever engine is chosen
    private func start(_ s: Song, autoplay: Bool) async {
        var url = s.url
        if OggOpus.isOpus(url) {
            let cached = Disk.decodedURL(s)
            if !FileManager.default.fileExists(atPath: cached.path) {
                decoding = true
                let src = s.url
                let err: String? = await Task.detached { () -> String? in
                    do { try OggOpus.decode(src, to: cached); return nil } catch { try? FileManager.default.removeItem(at: cached); return error.localizedDescription }
                }.value
                decoding = false
                guard current?.id == s.id else { return }
                if let e = err { isPlaying = false; Library.main?.flash("Couldn't play \(s.title): \(e)"); return }
            }
            url = cached
        }
        guard current?.id == s.id else { return }
        await prepareLevel(s, url: url)
        guard current?.id == s.id else { return }
        warmAnalysis()
        if UserDefaults.standard.bool(forKey: "enhancedEngine") {
            let g = geEngine()
            avp.pause(); avp.replaceCurrentItem(with: nil)
            if (try? g.load(url, autoplay: autoplay)) != nil { usingGE = true; refreshPreload(); return }
        }
        usingGE = false; ge?.stopAll()
        let item = AVPlayerItem(url: url)
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.ended() }
        }
        avp.replaceCurrentItem(with: item)
        if autoplay { avp.play(); if speed != 1 { avp.rate = speed } }
    }

    private func ended() {
        if sleepAtSongEnd { sleepAtSongEnd = false; engPause(); isPlaying = false; seek(to: 0); pushNowPlaying(); pushDiscord(); return }
        if let i = nextIndex() {
            if i == index { seek(to: 0); counted = false; engPlay(); isPlaying = true; if usingGE { /* restart the preloaded copy too */ refreshPreload() }; return }
            index = i; load(queue[i], autoplay: true)
        } else { engPause(); isPlaying = false; seek(to: 0); pushNowPlaying(); pushDiscord() }
    }

    func togglePlay() {
        guard current != nil else { return }
        if isPlaying { engPause() } else { engPlay() }
        isPlaying.toggle()
        pushNowPlaying(); pushDiscord()
    }

    func next() {
        guard !queue.isEmpty else { return }
        if index + 1 < queue.count { index += 1 } else if repeatMode == 1 || shuffle { index = 0 } else { return }
        if !counted, clock.position < 10, let c = current { Library.main?.recordSkip(c.id) }
        load(queue[index], autoplay: true)
    }

    func previous() {
        guard !queue.isEmpty else { return }
        if clock.position > 3 || index == 0 { seek(to: 0); return }
        index -= 1
        load(queue[index], autoplay: true)
    }

    func seek(to seconds: Double) {
        let t = max(0, min(seconds, max(duration - 0.1, 0)))
        if usingGE { ge?.seek(t) } else { avp.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
        clock.position = t
        pushNowPlaying(); pushDiscord()
    }

    func cycleRepeat() { repeatMode = (repeatMode + 1) % 3; refreshPreload() }

    // MARK: system integration (media keys, the menu bar, Control Centre)

    private func setupRemote() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in Task { @MainActor in if self?.isPlaying == false { self?.togglePlay() } }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in if self?.isPlaying == true { self?.togglePlay() } }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.togglePlay() }; return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            if let e = e as? MPChangePlaybackPositionCommandEvent { let p = e.positionTime; Task { @MainActor in self?.seek(to: p) } }
            return .success
        }
    }

    private func pushNowPlaying() {
        guard let s = current else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: s.title,
            MPMediaItemPropertyArtist: s.artist,
            MPMediaItemPropertyAlbumTitle: s.album,
            MPMediaItemPropertyPlaybackDuration: s.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: clock.position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(speed) : 0.0,
        ]
        if let img = Covers.image(s, maxPixel: 600) { info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img } }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    private func pushDiscord() {
        Discord.shared.update(song: current, playing: isPlaying, position: clock.position, duration: duration)
    }

    /// the Discord switch or its options changed
    func refreshDiscord() { pushDiscord() }
}

@MainActor
final class VolumeModel: ObservableObject { @Published var value: Float = 1 }

struct VolumeSlider: View {
    @ObservedObject var vol: VolumeModel
    var body: some View {
        Slider(value: Binding(get: { Double(vol.value) }, set: { Player.shared.volume = Float($0) }), in: 0...1)
    }
}
