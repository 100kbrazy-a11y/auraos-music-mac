import SwiftUI
import AppKit

struct GeneralSettings: View {
    @EnvironmentObject var lib: Library
    @AppStorage("liveYt") private var liveYt = true
    @AppStorage("homeReleases") private var homeReleases = true
    @AppStorage("resumeLast") private var resumeLast = true
    @AppStorage("menuBar") private var menuBar = true
    @AppStorage("menuLyrics") private var menuLyrics = true
    @AppStorage("miniOnTop") private var miniOnTop = true
    @AppStorage("notifySong") private var notifySong = false

    var body: some View {
        SettingsPage {
            SettingsGroup("Music library", footer: "The music folders are watched: songs you add or remove show up by themselves.") {
                if lib.folders.isEmpty { SettingNote("No folders yet. Add one to keep it up to date.") }
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
                    Button("Find Missing Covers") { lib.findMissingCovers() }
                    Button("Bring Over from Music…") { lib.importAppleMusic() }
                }
                HStack {
                    Text("\(lib.songs.count) songs").foregroundStyle(.secondary)
                    if !lib.status.isEmpty { Text(lib.status).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            SettingsGroup("Startup") {
                SettingToggle(title: "Pick up where I left off", help: "Opens with the last song loaded (paused) at the place you stopped.", isOn: $resumeLast)
                SettingToggle(title: "Look for new releases from my artists", help: "Once a week, for the Home page.", isOn: $homeReleases)
            }
            SettingsGroup("Search") {
                SettingToggle(title: "Show YouTube results while I type", help: "Songs that aren't in your library can be played or downloaded from the search box.", isOn: $liveYt)
            }
            SettingsGroup("Menu bar and windows") {
                SettingToggle(title: "Show the player in the menu bar", isOn: $menuBar)
                SettingToggle(title: "Show the current lyric in the menu bar player", isOn: $menuLyrics)
                SettingToggle(title: "Keep the mini player above other windows", isOn: $miniOnTop)
                SettingToggle(title: "Show a notification when the song changes", help: "Only while the app is in the background.", isOn: $notifySong)
                    .onChange(of: notifySong) { on in if on { Notifier.authorize() } }
            }
            SettingsGroup("Opus and Ogg files") {
                SettingNote("Opus files (the Android app's music packs and .opus exports) play here too. The first time one plays it is decoded once and kept, so it can take a moment. WebM files still aren't supported.")
            }
        }
    }
}

struct PlaybackSettings: View {
    @AppStorage("enhancedEngine") private var enhanced = false
    @AppStorage("crossfade") private var crossfade = 0.0
    @AppStorage("eqPreset") private var preset = "Flat"
    @AppStorage("levelVolume") private var level = true
    @AppStorage("pitchFollowsSpeed") private var pitchFollows = true
    @AppStorage("prevRestart") private var prevRestart = 3.0
    @ObservedObject private var outputs = AudioOutputs.shared
    @State private var gains: [Double] = (UserDefaults.standard.array(forKey: "eqGains") as? [Double]) ?? Array(repeating: 0, count: 10)
    private let labels = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    var body: some View {
        SettingsPage {
            SettingsGroup("Engine", footer: enhanced ? "Enhanced: gapless playback, crossfade, the equaliser and speed. It applies from the next song you start. If anything sounds wrong, switch back to Standard." : "Standard: Apple's player. Reliable. Switch to Enhanced for gapless playback, crossfade, the equaliser and speed.") {
                SettingRow("Playback engine") {
                    Picker("", selection: $enhanced) {
                        Text("Standard").tag(false)
                        Text("Enhanced (new)").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                }
            }
            SettingsGroup("Speed and buttons") {
                SettingToggle(title: "Pitch follows speed", help: pitchFollows ? "Speeding a song up makes it higher and slowing it down makes it lower, like a record (2× is an octave up). Turn this off to change the speed without changing the pitch." : "The speed changes and the pitch stays the same. Turn this on to make sped-up songs higher and slowed-down songs lower.", isOn: $pitchFollows)
                SliderRow(title: "Previous button restarts the song after", help: "Press it later than this and it goes back to the start; sooner and it goes to the song before. 0 always goes back a song.", value: $prevRestart, range: 0...10, step: 1, standard: 3, unit: " s")
            }
            SettingsGroup("Sound") {
                SettingToggle(title: "Level the volume between songs", help: "Each song is measured once, then played at a common level so a quiet song isn't followed by a loud one. The standard engine can only turn loud songs down; the enhanced engine can also lift quiet ones a little.", isOn: $level)
                SettingMenu("Output", selection: $outputs.selected) {
                    Text("System Default").tag("")
                    ForEach(outputs.devices) { Text($0.name).tag($0.uid) }
                }
            }
            SettingsGroup("Enhanced engine", footer: enhanced ? nil : "Turn on the Enhanced engine above to use these.") {
                SliderRow(title: "Crossfade", help: "The end of one song fades into the start of the next.", value: $crossfade, range: 0...12, step: 1, standard: 0, unit: " s")
                SettingMenu("Equaliser", selection: $preset) {
                    ForEach(GaplessEngine.presets, id: \.0) { Text($0.0).tag($0.0) }
                    Text("Custom").tag("Custom")
                }
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(0..<10, id: \.self) { i in
                        VStack(spacing: 4) {
                            Slider(value: Binding(get: { shown(i) }, set: { v in setGain(i, v) }), in: -12...12).rotationEffect(.degrees(-90)).frame(width: 90, height: 90).frame(width: 22, height: 96)
                            Text(labels[i]).font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }.padding(.top, 4)
            }
            .disabled(!enhanced)
        }
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
        SettingsPage {
            SettingsGroup("Saving", footer: "Songs from YouTube are saved as M4A (AAC) files with their title, artist, album and cover, then added to your library. Search and download from the YouTube page in the sidebar, or from the search box when a song isn't in your library.") {
                SettingRow("Save songs in") {
                    HStack {
                        Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).frame(maxWidth: 220, alignment: .trailing)
                        Button("Choose…") { choose() }
                        Button { NSWorkspace.shared.open(folder) } label: { Image(systemName: "arrow.up.forward.square") }.help("Show in Finder")
                    }
                }
                SettingRow("Songs downloading at once") { Stepper("\(parallel)", value: $parallel, in: 1...4) }
            }
            SettingsGroup("Now") {
                SettingValue("Downloading", "\(Downloads.shared.active)")
                HStack { Button("Open the Downloads page") { NotificationCenter.default.post(name: .showDownloads, object: nil); NSApp.activate(ignoringOtherApps: true) }; Spacer() }
            }
        }
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
        SettingsPage {
            SettingsGroup("Rich Presence", footer: "This talks to the Discord app on this Mac, the same way its own Rich Presence does: no sign-in, no token. Keep Discord open, and turn on Settings › Activity Privacy › Share my activity in Discord.") {
                HStack(spacing: 8) {
                    Circle().fill(!on ? Color.gray : status.hasPrefix("Discord isn't") ? Color.orange : Color.green).frame(width: 9, height: 9)
                    Text(on ? status : "Off").foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("Test") { Discord.shared.test() }.disabled(!on)
                }
                SettingToggle(title: "Show what I'm listening to on Discord", isOn: $on)
                SettingToggle(title: "Show the album cover", isOn: $cover)
                SettingToggle(title: "Show the song's progress", isOn: $timeline)
                SettingToggle(title: "Clear my status while music is paused", isOn: $hidePaused)
            }
        }
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
        SettingsPage {
            SettingsGroup("Strata Music") {
                SettingValue("Version", Updater.current)
                SettingToggle(title: "Check for updates when the app opens", isOn: $auto)
                HStack {
                    Button("Check Now") { Task { await updater.check() } }.disabled(updater.busy)
                    if let r = updater.available { Button("Update to \(r.version)") { Task { await updater.install() } }.disabled(updater.busy) }
                    if updater.busy { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if !updater.status.isEmpty { Text(updater.status).foregroundStyle(.secondary) }
            }
            if let r = updater.available, let b = r.body, !b.isEmpty {
                SettingsGroup("What's new in \(r.version)") { Text(b).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }
}
