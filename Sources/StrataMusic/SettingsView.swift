import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            DiscordSettings().tabItem { Label("Discord", systemImage: "gamecontroller") }
            UpdateSettings().tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 520, height: 400)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var lib: Library
    @AppStorage("leaves") private var leaves = true

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
            }
            Section("Player") {
                Toggle("Falling leaves (The Thanksgiving Update)", isOn: $leaves)
            }
            Section("Songs this Mac can't play yet") {
                Text("Opus, Ogg and WebM files (from Android music packs) are skipped for now. Export them as M4A or FLAC on the phone, or wait for the next update.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct DiscordSettings: View {
    @AppStorage("discordOn") private var on = false
    @AppStorage("discordCover") private var cover = true
    @AppStorage("discordHidePaused") private var hidePaused = true
    @AppStorage("discordTimeline") private var timeline = true

    var body: some View {
        Form {
            Section {
                Toggle("Show what I'm listening to on Discord", isOn: $on)
                Toggle("Show the album cover", isOn: $cover)
                Toggle("Show the song's progress", isOn: $timeline)
                Toggle("Clear my status while music is paused", isOn: $hidePaused)
            } footer: {
                Text("This talks to the Discord app on this Mac, the same way its own Rich Presence does: no sign-in, no token. Keep Discord open, and turn on Settings › Activity Privacy › Share my activity in Discord.")
            }
        }
        .formStyle(.grouped)
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
                LabeledContent("Version", value: Updater.current)
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
        .formStyle(.grouped)
    }
}
