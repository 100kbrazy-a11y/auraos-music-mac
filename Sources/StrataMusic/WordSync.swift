import SwiftUI
import AppKit

/// finds when each word is sung (Aligner.swift), one song at a time, quietly in the background
@MainActor
final class WordSync: ObservableObject {
    static let shared = WordSync()

    @Published var busyID: String? = nil
    @Published var progress = 0.0
    @Published var lastError: String? = nil

    private var tried: Set<String> = []

    init() {
        // an earlier version used a large downloaded model; it isn't needed any more
        try? FileManager.default.removeItem(at: Disk.dir.appendingPathComponent("models", isDirectory: true))
        try? FileManager.default.removeItem(at: Disk.dir.appendingPathComponent("align", isDirectory: true))
        // timings made by an older version of the timing code are made again
        if UserDefaults.standard.integer(forKey: "alignerGeneration") < 4 {
            Self.deleteAlignedFiles()
            UserDefaults.standard.set(4, forKey: "alignerGeneration")
        }
    }

    private static func deleteAlignedFiles() {
        let dir = Disk.dir.appendingPathComponent("lyrics", isDirectory: true)
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix(".aligned.lrc") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
    }

    var auto: Bool { UserDefaults.standard.object(forKey: "preciseSync") as? Bool ?? true }

    /// called whenever a song's lyrics have loaded: starts the work by itself unless you turned that off
    func consider(_ s: Song) {
        guard auto, busyID == nil, !tried.contains(s.id) else { return }
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        let store = LyricsStore.shared
        guard store.loadedID == s.id, store.synced, !store.wordSynced else { return }
        run(s)
    }

    func run(_ s: Song) {
        guard busyID == nil else { return }
        let store = LyricsStore.shared
        guard store.loadedID == s.id, store.synced else { return }
        tried.insert(s.id)
        busyID = s.id
        progress = 0
        lastError = nil
        let lines = store.lines, offset = store.offset
        let url = s.url
        Task.detached(priority: .utility) { [weak self] in
            var text: String? = nil
            var failure: String? = nil
            do {
                text = try Aligner.align(url: url, lines: lines, offset: offset) { p in
                    Task { @MainActor in self?.progress = p }
                }
            } catch { failure = error.localizedDescription }
            let result = text, problem = failure
            await MainActor.run { self?.finish(s, result, problem) }
        }
    }

    private func finish(_ s: Song, _ text: String?, _ problem: String?) {
        busyID = nil
        progress = 0
        if let problem { lastError = problem; return }
        guard let text else { lastError = "Couldn't find the singing in \"\(s.title)\""; return }
        let store = LyricsStore.shared
        try? text.write(to: store.alignedURL(s.id), atomically: true, encoding: .utf8)
        if store.loadedID == s.id, store.mergeAligned(id: s.id) { store.setOffset(0, song: s) }
    }

    /// deletes every precise timing and shows the lyrics as they were
    func forgetAll() {
        Self.deleteAlignedFiles()
        tried = []
        if let s = Player.shared.current { Task { await LyricsStore.shared.load(for: s) } }
    }
}

/// the part of Settings that controls it
struct WordSyncSection: View {
    @ObservedObject private var sync = WordSync.shared
    @AppStorage("preciseSync") private var auto = true

    var body: some View {
        SettingsGroup("Word timing", footer: "Strata listens to a song once (about as long as it takes to read the file), picks out the voice and lines each word up with it, so the lit word follows the singer and ad-libs don't cut a line short. It runs on your Mac, in the background, with nothing to download, and works best when the vocals are in the middle of the mix.") {
            SettingToggle(title: "Time the words to the singing automatically", isOn: $auto)
            if sync.busyID != nil { HStack { ProgressView(value: sync.progress).frame(maxWidth: .infinity); Text("Listening…").foregroundStyle(.secondary) } }
            if let e = sync.lastError { Text(e).font(.callout).foregroundStyle(.red) }
            HStack { Button("Forget all word timings") { sync.forgetAll() }; Spacer() }
        }
    }
}
