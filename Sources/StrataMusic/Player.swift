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
    @Published var volume: Float = 1 { didSet { avp.volume = volume } }
    let clock = Clock()

    private let avp = AVPlayer()
    private var baseQueue: [Song] = []
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var lastNowPlayingPush = 0.0

    var duration: Double { current?.duration ?? 0 }

    private init() {
        timeObserver = avp.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            let s = t.seconds
            Task { @MainActor in
                guard let self = self, s.isFinite else { return }
                self.clock.position = s
            }
        }
        setupRemote()
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

    func playNext(_ s: Song) { if queue.isEmpty { play(s, in: [s]) } else { queue.insert(s, at: min(index + 1, queue.count)) } }
    func enqueue(_ s: Song) { if queue.isEmpty { play(s, in: [s]) } else { queue.append(s) } }

    private func reshuffle() {
        guard let cur = current, !baseQueue.isEmpty else { return }
        if shuffle {
            var rest = baseQueue.filter { $0.id != cur.id }; rest.shuffle()
            queue = [cur] + rest; index = 0
        } else {
            queue = baseQueue; index = queue.firstIndex(where: { $0.id == cur.id }) ?? 0
        }
    }

    // MARK: transport

    private func load(_ s: Song, autoplay: Bool) {
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        let item = AVPlayerItem(url: s.url)
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.ended() }
        }
        avp.replaceCurrentItem(with: item)
        current = s
        accent = Covers.accent(s)
        clock.position = 0
        if autoplay { avp.play(); isPlaying = true } else { isPlaying = false }
        pushNowPlaying(); pushDiscord()
    }

    private func ended() {
        if repeatMode == 2 { seek(to: 0); avp.play(); isPlaying = true; return }
        if index + 1 < queue.count { index += 1; load(queue[index], autoplay: true) }
        else if repeatMode == 1, !queue.isEmpty { index = 0; load(queue[0], autoplay: true) }
        else { avp.pause(); isPlaying = false; seek(to: 0); pushNowPlaying(); pushDiscord() }
    }

    func togglePlay() {
        guard current != nil else { return }
        if isPlaying { avp.pause() } else { avp.play() }
        isPlaying.toggle()
        pushNowPlaying(); pushDiscord()
    }

    func next() {
        guard !queue.isEmpty else { return }
        if index + 1 < queue.count { index += 1 } else if repeatMode == 1 || shuffle { index = 0 } else { return }
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
        avp.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        clock.position = t
        pushNowPlaying(); pushDiscord()
    }

    func cycleRepeat() { repeatMode = (repeatMode + 1) % 3 }

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
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
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
