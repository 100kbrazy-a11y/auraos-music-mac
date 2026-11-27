import SwiftUI
import AppKit

// The building blocks of the Settings pages: one look for every row, so the pages line up.

/// a slider row: the name (with a line of explanation) on the left, the slider and its value on the right, and a reset arrow once it has been changed
struct SliderRow: View {
    let title: String
    var help: String? = nil
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    let standard: Double
    var unit = ""
    var scale = 1.0              // the shown number is the value times this (0.55 shown as 55 %)
    var decimals = 0

    private var shown: String {
        let v = value * scale
        return (decimals == 0 ? "\(Int(v.rounded()))" : String(format: "%.\(decimals)f", v)) + unit
    }

    @ViewBuilder private var slider: some View {
        if step > 0 { Slider(value: $value, in: range, step: step) } else { Slider(value: $value, in: range) }
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let h = help { Text(h).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            slider.frame(width: 180)
            Text(shown).monospacedDigit().foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
            Button { value = standard } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(.borderless).help("Back to the usual setting")
                .opacity(abs(value - standard) > 0.0001 ? 1 : 0)
                .disabled(abs(value - standard) <= 0.0001)
        }
    }
}

/// a switch with an optional line of explanation under it
struct SettingToggle: View {
    let title: String
    var help: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(title, isOn: $isOn)
            if let h = help { Text(h).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// a row of choices (segmented), with an optional line of explanation
struct SettingChoice: View {
    let title: String
    var help: String? = nil
    @Binding var selection: String
    let options: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.segmented)
            if let h = help { Text(h).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// a line of small grey text for a section's footer or a note
struct SettingNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
}

/// puts the settings it lists back to their usual values
struct ResetButton: View {
    let title: String
    let keys: [String]
    var after: () -> Void = {}

    var body: some View {
        HStack {
            Spacer()
            Button {
                for k in keys { UserDefaults.standard.removeObject(forKey: k) }
                after()
            } label: { Label(title, systemImage: "arrow.counterclockwise") }
            .buttonStyle(.borderless)
        }
    }
}

// MARK: - the window: a sidebar of pages and the page itself

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, look, player, visualizer, lyrics, playback, downloads, sync, discord, updates, advanced
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .look: return "Look"
        case .player: return "Player"
        case .visualizer: return "Visualizer"
        case .lyrics: return "Lyrics"
        case .playback: return "Playback"
        case .downloads: return "Downloads"
        case .sync: return "Sync"
        case .discord: return "Discord"
        case .updates: return "Updates"
        case .advanced: return "Advanced"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "Your music folders, what happens at startup, and the menu bar."
        case .look: return "Colours, glass, seasons, the app icon and how lists look."
        case .player: return "The full-screen player and the media bar: sizes, shapes, buttons, pages."
        case .visualizer: return "The moving bars in the player: height, where they sit, how many, what colour."
        case .lyrics: return "How lyrics look and how their words are timed."
        case .playback: return "The audio engine, speed and pitch, volume levelling, the equaliser."
        case .downloads: return "Where YouTube downloads are saved."
        case .sync: return "Share likes, playlists and play counts between your devices."
        case .discord: return "Show what you're listening to on Discord."
        case .updates: return "The version you have and new ones."
        case .advanced: return "Shortcuts and scripts, YouTube tests and the engine log."
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .look: return "paintpalette.fill"
        case .player: return "play.rectangle.fill"
        case .visualizer: return "waveform"
        case .lyrics: return "quote.bubble.fill"
        case .playback: return "speaker.wave.2.fill"
        case .downloads: return "arrow.down.circle.fill"
        case .sync: return "arrow.triangle.2.circlepath"
        case .discord: return "gamecontroller.fill"
        case .updates: return "arrow.down.app.fill"
        case .advanced: return "wrench.and.screwdriver.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .gray
        case .look: return .pink
        case .player: return .purple
        case .visualizer: return .orange
        case .lyrics: return .indigo
        case .playback: return .red
        case .downloads: return .blue
        case .sync: return .teal
        case .discord: return Color(red: 0.35, green: 0.4, blue: 0.95)
        case .updates: return .green
        case .advanced: return .secondary
        }
    }

    /// the sidebar's groups
    static let groups: [(String, [SettingsTab])] = [
        ("App", [.general, .look, .player, .visualizer, .lyrics]),
        ("Sound", [.playback]),
        ("Library", [.downloads, .sync]),
        ("Connect", [.discord]),
        ("About", [.updates, .advanced]),
    ]
}

struct SettingsView: View {
    @AppStorage("settingsTab") private var tabName = SettingsTab.general.rawValue

    private var tab: SettingsTab { SettingsTab(rawValue: tabName) ?? .general }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 196)
                .background(Color.primary.opacity(0.04))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tab.title).font(.system(size: 24, weight: .bold))
                    Text(tab.subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                .padding(.horizontal, 26).padding(.top, 20).padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 880, height: 660)
    }

    private var sidebar: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(SettingsTab.groups, id: \.0) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.0.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 10).padding(.bottom, 2)
                        ForEach(group.1) { t in row(t) }
                    }
                }
            }
            .padding(10)
        }
    }

    private func row(_ t: SettingsTab) -> some View {
        Button { tabName = t.rawValue } label: {
            HStack(spacing: 9) {
                Image(systemName: t.icon).font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(t.tint))
                Text(t.title).font(.system(size: 13, weight: tab == t ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tab == t ? Color.accentColor.opacity(0.22) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var page: some View {
        switch tab {
        case .general: GeneralSettings()
        case .look: LookSettings()
        case .player: PlayerSettings()
        case .visualizer: VisualizerSettings()
        case .lyrics: LyricsSettings()
        case .playback: PlaybackSettings()
        case .downloads: DownloadSettings()
        case .sync: SyncSettings()
        case .discord: DiscordSettings()
        case .updates: UpdateSettings()
        case .advanced: AdvancedSettings()
        }
    }
}
