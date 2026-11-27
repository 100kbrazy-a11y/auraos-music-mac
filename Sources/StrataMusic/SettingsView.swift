import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            LookSettings().tabItem { Label("Look", systemImage: "paintpalette") }
            PlaybackSettings().tabItem { Label("Playback", systemImage: "speaker.wave.2") }
            DownloadSettings().tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
            DiscordSettings().tabItem { Label("Discord", systemImage: "gamecontroller") }
            SyncSettings().tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
            AdvancedSettings().tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
            UpdateSettings().tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 540, height: 430)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var lib: Library
    @AppStorage("liveYt") private var liveYt = true
    @AppStorage("homeReleases") private var homeReleases = true
    @AppStorage("menuBar") private var menuBar = true
    @AppStorage("miniOnTop") private var miniOnTop = true
    @AppStorage("notifySong") private var notifySong = false
    @AppStorage("menuLyrics") private var menuLyrics = true
    @AppStorage("censorLyrics") private var censorLyrics = false
    @AppStorage("lyricsWords") private var lyricsWords = true

    var body: some View {
        Form {
            Section("Music") {
                if lib.folders.isEmpty { Text("No folders yet. Add one to keep it up to date.").foregroundStyle(.secondary) }
                ForEach(lib.folders, id: \.self) { f in
                    HStack {
                        Image(systemName: "folder"); Text(f).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Remove") { lib.folders.removeAll { $0 == f }; lib.save() }.buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button("Add Music…") { lib.pickMusic() }
                    Button("Rescan") { lib.rescan() }
                    Text("\(lib.songs.count) songs").foregroundStyle(.secondary)
                    if !lib.status.isEmpty { Text(lib.status).foregroundStyle(.secondary).lineLimit(1) }
                }
                HStack {
                    Button("Find Missing Covers") { lib.findMissingCovers() }
                    Button("Bring Over from Music…") { lib.importAppleMusic() }
                }
                Text("The music folders are watched: songs you add or remove show up by themselves.").font(.callout).foregroundStyle(.secondary)
            }
            Section("Player") {
                Toggle("Show YouTube results while I type in search", isOn: $liveYt)
                Toggle("Look for new releases from my artists (weekly)", isOn: $homeReleases)
                Toggle("Show the player in the menu bar", isOn: $menuBar)
                Toggle("Show the current lyric in the menu bar player", isOn: $menuLyrics)
                Toggle("Light up lyrics word by word", isOn: $lyricsWords)
                Toggle("Hide bad words in lyrics", isOn: $censorLyrics)
                Toggle("Keep the mini player above other windows", isOn: $miniOnTop)
                Toggle("Show a notification when the song changes (while the app is in the background)", isOn: $notifySong)
                    .onChange(of: notifySong) { on in if on { Notifier.authorize() } }
            }
            WordSyncSection()
            Section("Opus and Ogg files") {
                Text("Opus files (the Android app's music packs and .opus exports) play here too. The first time one plays it is decoded once and kept, so it can take a moment. WebM files still aren't supported.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .groupedForm(clearBackground: true).settingsPage()
    }
}

struct PlaybackSettings: View {
    @AppStorage("enhancedEngine") private var enhanced = false
    @AppStorage("crossfade") private var crossfade = 0.0
    @AppStorage("eqPreset") private var preset = "Flat"
    @AppStorage("levelVolume") private var level = true
    @AppStorage("pitchFollowsSpeed") private var pitchFollows = true
    @ObservedObject private var outputs = AudioOutputs.shared
    @State private var gains: [Double] = (UserDefaults.standard.array(forKey: "eqGains") as? [Double]) ?? Array(repeating: 0, count: 10)
    private let labels = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    var body: some View {
        Form {
            Section {
                Picker("Playback engine", selection: $enhanced) {
                    Text("Standard").tag(false)
                    Text("Enhanced (new)").tag(true)
                }
                .pickerStyle(.segmented)
                Text(enhanced ? "Enhanced: gapless playback, crossfade, the equaliser and speed. It applies from the next song you start. If anything sounds wrong, switch back to Standard." : "Standard: Apple's player. Reliable. Switch to Enhanced for gapless playback, crossfade, the equaliser and speed.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Speed") {
                Toggle("Pitch follows speed", isOn: $pitchFollows)
                Text(pitchFollows ? "Speeding a song up makes it higher and slowing it down makes it lower, like a record (2× is an octave up). Turn this off to change the speed without changing the pitch." : "The speed changes and the pitch stays the same. Turn this on to make sped-up songs higher and slowed-down songs lower.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Sound") {
                Toggle("Level the volume between songs", isOn: $level)
                Text("Each song is measured once, then played at a common level so a quiet song isn't followed by a loud one. The standard engine can only turn loud songs down; the enhanced engine can also lift quiet ones a little.").font(.callout).foregroundStyle(.secondary)
                Picker("Output", selection: $outputs.selected) {
                    Text("System Default").tag("")
                    ForEach(outputs.devices) { Text($0.name).tag($0.uid) }
                }
            }
            Section("Enhanced engine") {
                HStack { Text("Crossfade"); Slider(value: $crossfade, in: 0...12, step: 1); Text(crossfade == 0 ? "Off" : "\(Int(crossfade)) s").monospacedDigit().frame(width: 36, alignment: .trailing) }
                Picker("Equaliser", selection: $preset) {
                    ForEach(GaplessEngine.presets, id: \.0) { Text($0.0).tag($0.0) }
                    Text("Custom").tag("Custom")
                }
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(0..<10, id: \.self) { i in
                        VStack(spacing: 4) {
                            Slider(value: Binding(get: { shown(i) }, set: { v in setGain(i, v) }), in: -12...12).rotationEffect(.degrees(-90)).frame(width: 90, height: 90).frame(width: 22, height: 96)
                            Text(labels[i]).font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                }.frame(maxWidth: .infinity).padding(.top, 4)
            }
            .disabled(!enhanced)
        }
        .groupedForm(clearBackground: true).settingsPage()
        .onChange(of: level) { _ in Player.shared.refreshAnalysis() }
        .onChange(of: pitchFollows) { _ in Player.shared.applySpeedMode() }
        .onChange(of: enhanced) { _ in Player.shared.applyAudioSettings() }
        .onChange(of: crossfade) { _ in Player.shared.applyAudioSettings() }
        .onChange(of: preset) { _ in Player.shared.applyAudioSettings() }
    }

    private func shown(_ i: Int) -> Double {
        if preset == "Custom" { return gains[i] }
        return Double(GaplessEngine.presets.first { $0.0 == preset }?.1[i] ?? 0)
    }
    private func setGain(_ i: Int, _ v: Double) {
        if preset != "Custom" { gains = GaplessEngine.presets.first { $0.0 == preset }?.1.map { Double($0) } ?? gains; preset = "Custom" }
        gains[i] = v
        UserDefaults.standard.set(gains, forKey: "eqGains")
        Player.shared.applyAudioSettings()
    }
}

struct DownloadSettings: View {
    @EnvironmentObject var lib: Library
    @AppStorage("dlParallel") private var parallel = 2
    @State private var folder = Downloads.folder

    var body: some View {
        Form {
            Section {
                CompatLabeled("Save songs in") {
                    HStack {
                        Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…") { choose() }
                        Button { NSWorkspace.shared.open(folder) } label: { Image(systemName: "arrow.up.forward.square") }.help("Show in Finder")
                    }
                }
                Stepper("Songs downloading at once: \(parallel)", value: $parallel, in: 1...4)
            } footer: {
                Text("Songs from YouTube are saved as M4A (AAC) files with their title, artist, album and cover, then added to your library. Search and download from the YouTube page in the sidebar, or from the search box when a song isn't in your library.")
            }
            Section("Now") {
                CompatLabeled("Downloading", value: "\(Downloads.shared.active)")
                Button("Open the Downloads page") { NotificationCenter.default.post(name: .showDownloads, object: nil); NSApp.activate(ignoringOtherApps: true) }
            }
        }
        .groupedForm(clearBackground: true).settingsPage()
    }

    private func choose() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true; p.prompt = "Choose"
        p.directoryURL = folder
        if p.runModal() == .OK, let u = p.url { Downloads.folder = u; folder = u }
    }
}

struct DiscordSettings: View {
    @AppStorage("discordOn") private var on = true
    @State private var status = Discord.shared.status
    @AppStorage("discordCover") private var cover = true
    @AppStorage("discordHidePaused") private var hidePaused = true
    @AppStorage("discordTimeline") private var timeline = true

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    Circle().fill(!on ? Color.gray : status.hasPrefix("Discord isn't") ? Color.orange : Color.green).frame(width: 9, height: 9)
                    Text(on ? status : "Off").foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("Test") { Discord.shared.test() }.disabled(!on)
                }
                Toggle("Show what I'm listening to on Discord", isOn: $on)
                Toggle("Show the album cover", isOn: $cover)
                Toggle("Show the song's progress", isOn: $timeline)
                Toggle("Clear my status while music is paused", isOn: $hidePaused)
            } footer: {
                Text("This talks to the Discord app on this Mac, the same way its own Rich Presence does: no sign-in, no token. Keep Discord open, and turn on Settings › Activity Privacy › Share my activity in Discord.")
            }
        }
        .groupedForm(clearBackground: true).settingsPage()
        .onReceive(NotificationCenter.default.publisher(for: Discord.statusChanged)) { _ in status = Discord.shared.status }
        .onChange(of: on) { _ in Player.shared.refreshDiscord() }
        .onChange(of: cover) { _ in Player.shared.refreshDiscord() }
        .onChange(of: hidePaused) { _ in Player.shared.refreshDiscord() }
        .onChange(of: timeline) { _ in Player.shared.refreshDiscord() }
    }
}

struct UpdateSettings: View {
    @EnvironmentObject var updater: Updater
    @AppStorage("autoUpdate") private var auto = true

    var body: some View {
        Form {
            Section {
                CompatLabeled("Version", value: Updater.current)
                Toggle("Check for updates when the app opens", isOn: $auto)
                HStack {
                    Button("Check Now") { Task { await updater.check() } }.disabled(updater.busy)
                    if let r = updater.available { Button("Update to \(r.version)") { Task { await updater.install() } }.disabled(updater.busy) }
                    if updater.busy { ProgressView().controlSize(.small) }
                }
                if !updater.status.isEmpty { Text(updater.status).foregroundStyle(.secondary) }
            }
            if let r = updater.available, let b = r.body, !b.isEmpty {
                Section("What's new in \(r.version)") { Text(b).font(.callout).textSelection(.enabled) }
            }
        }
        .groupedForm(clearBackground: true).settingsPage()
    }
}
