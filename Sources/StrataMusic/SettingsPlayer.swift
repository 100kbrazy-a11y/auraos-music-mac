import SwiftUI
import AppKit

// MARK: - Settings > Player

struct PlayerSettings: View {
    @AppStorage("playerStart") private var playerStart = 1
    @AppStorage("playerPages") private var playerPages = "0,1,2"
    @AppStorage("showPill") private var showPill = true
    @AppStorage("playerCover") private var playerCover = 1.0
    @AppStorage("coverShape") private var coverShape = "rounded"
    @AppStorage("coverRadius") private var coverRadius = 24.0
    @AppStorage("coverShadow") private var coverShadow = true
    @AppStorage("coverShadowAmount") private var shadowAmount = 1.0
    @AppStorage("coverPauseShrink") private var pauseShrink = true
    @AppStorage("titleSize") private var titleSize = 30.0
    @AppStorage("showAlbum") private var showAlbum = true
    @AppStorage("pbSpeed") private var pbSpeed = true
    @AppStorage("pbRoute") private var pbRoute = true
    @AppStorage("pbSleep") private var pbSleep = true
    @AppStorage("pbQueue") private var pbQueue = true
    @AppStorage("pbExport") private var pbExport = true
    @AppStorage("barCompact") private var barCompact = false
    @AppStorage("barHeart") private var barHeart = true
    @AppStorage("barQueue") private var barQueue = true
    @AppStorage("barWidth") private var barWidth = 720.0
    @AppStorage("barCover") private var barCover = 46.0
    @AppStorage("barBottom") private var barBottom = 14.0
    private let pageNames = ["Lyrics", "Current Song", "Artist"]

    private func movePage(_ p: Int, _ by: Int) {
        var a = PlayerPages.parse(playerPages)
        guard let i = a.firstIndex(of: p), a.indices.contains(i + by) else { return }
        a.swapAt(i, i + by)
        playerPages = PlayerPages.text(a)
    }

    var body: some View {
        SettingsPage {
            SettingsGroup("Pages") {
                SettingMenu("Opens on", selection: $playerStart) {
                    Text("Lyrics").tag(0); Text("Current Song").tag(1); Text("Artist").tag(2)
                }
                ForEach(PlayerPages.parse(playerPages), id: \.self) { p in
                    HStack {
                        Text(pageNames[p])
                        Spacer()
                        Button { movePage(p, -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
                        Button { movePage(p, 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                    }
                }
                SettingNote("The order here is the order of the tabs, and the order you swipe through them.")
                SettingToggle(title: "Show the tab pill at the bottom", help: "Hide it to swipe between the pages without any buttons.", isOn: $showPill)
            }
            SettingsGroup("Cover") {
                SliderRow(title: "Size", value: $playerCover, range: 0.6...1.15, standard: 1, unit: "%", scale: 100)
                SettingChoice(title: "Shape", selection: $coverShape, options: [("rounded", "Rounded"), ("square", "Square"), ("circle", "Circle")])
                if coverShape == "rounded" {
                    SliderRow(title: "Corner roundness", value: $coverRadius, range: 0...60, step: 1, standard: 24)
                }
                SettingToggle(title: "Shadow under the cover", isOn: $coverShadow)
                if coverShadow {
                    SliderRow(title: "Shadow strength", value: $shadowAmount, range: 0.2...2, standard: 1, unit: "%", scale: 100)
                }
                SettingToggle(title: "Shrink the cover a little while paused", isOn: $pauseShrink)
            }
            SettingsGroup("Song info") {
                SliderRow(title: "Title size", value: $titleSize, range: 20...48, step: 1, standard: 30)
                SettingToggle(title: "Show the album name", isOn: $showAlbum)
            }
            SettingsGroup("Buttons under the controls") {
                SettingToggle(title: "Speed", isOn: $pbSpeed)
                SettingToggle(title: "AirPlay", isOn: $pbRoute)
                SettingToggle(title: "Sleep timer", isOn: $pbSleep)
                SettingToggle(title: "Up Next", isOn: $pbQueue)
                SettingToggle(title: "Export", isOn: $pbExport)
            }
            SettingsGroup("Media bar") {
                SettingToggle(title: "Compact", help: "No seek bar and a smaller cover.", isOn: $barCompact)
                SettingToggle(title: "Like button", isOn: $barHeart)
                SettingToggle(title: "Up Next button", isOn: $barQueue)
                SliderRow(title: "Width", value: $barWidth, range: 480...1000, step: 10, standard: 720, unit: " pt")
                SliderRow(title: "Cover size", value: $barCover, range: 32...72, step: 2, standard: 46, unit: " pt")
                SliderRow(title: "Distance from the bottom", value: $barBottom, range: 0...60, step: 1, standard: 14, unit: " pt")
            }
            SettingsGroup {
                ResetButton(title: "Reset the player to the usual look", keys: ["playerStart", "playerPages", "showPill", "playerCover", "coverShape", "coverRadius", "coverShadow", "coverShadowAmount", "coverPauseShrink", "titleSize", "showAlbum", "pbSpeed", "pbRoute", "pbSleep", "pbQueue", "pbExport", "barCompact", "barHeart", "barQueue", "barWidth", "barCover", "barBottom"])
            }
        }
    }
}

// MARK: - Settings > Visualizer

struct VisualizerSettings: View {
    @AppStorage("visualizer") private var visualizer = "bars"
    @AppStorage("vizHeight") private var height = 110.0
    @AppStorage("vizPosition") private var position = "bottom"
    @AppStorage("vizOffset") private var offset = 80.0
    @AppStorage("vizSide") private var side = 40.0
    @AppStorage("vizOpacity") private var strength = 0.55
    @AppStorage("vizBars") private var bars = 32
    @AppStorage("vizGap") private var gap = 4.0
    @AppStorage("vizRound") private var round = 1.0
    @AppStorage("vizColor") private var colorMode = "accent"
    @AppStorage("vizBoost") private var boost = 1.0
    @AppStorage("vizLyrics") private var onLyrics = true
    @AppStorage("vizSong") private var onSong = true
    @AppStorage("vizArtist") private var onArtist = true

    var body: some View {
        SettingsPage {
            SettingsGroup("Style") {
                SettingChoice(title: "Style", selection: $visualizer, options: [("bars", "Bars"), ("mirror", "Mirrored"), ("off", "Off")])
                SettingChoice(title: "Colour", help: "Accent follows the song's cover colour.", selection: $colorMode, options: [("accent", "Accent"), ("white", "White"), ("rainbow", "Rainbow")])
            }
            SettingsGroup("Size and place") {
                SliderRow(title: "Height", value: $height, range: 40...400, step: 5, standard: 110, unit: " pt")
                SettingChoice(title: "Position", selection: $position, options: [("bottom", "Bottom"), ("middle", "Middle"), ("top", "Top")])
                SliderRow(title: "Distance from the edge", help: position == "middle" ? "Not used in the middle." : nil, value: $offset, range: 0...300, step: 5, standard: 80, unit: " pt")
                SliderRow(title: "Space at the sides", help: "More space makes the bars narrower.", value: $side, range: 0...300, step: 5, standard: 40, unit: " pt")
            }
            SettingsGroup("Bars") {
                SliderRow(title: "Number of bars", value: Binding(get: { Double(bars) }, set: { bars = Int($0) }), range: 8...32, step: 4, standard: 32)
                SliderRow(title: "Gap between bars", value: $gap, range: 0...14, step: 1, standard: 4, unit: " pt")
                SliderRow(title: "Rounded ends", value: $round, range: 0...3, standard: 1, unit: "%", scale: 100)
                SliderRow(title: "Strength", help: "How visible the bars are.", value: $strength, range: 0.1...1, standard: 0.55, unit: "%", scale: 100)
                SliderRow(title: "Sensitivity", help: "Higher makes quiet parts of a song move the bars more.", value: $boost, range: 0.5...2, standard: 1, unit: "×", decimals: 1)
            }
            SettingsGroup("Show it on") {
                SettingToggle(title: "Lyrics page (drawn fainter)", isOn: $onLyrics)
                SettingToggle(title: "Current Song page", isOn: $onSong)
                SettingToggle(title: "Artist page", isOn: $onArtist)
            }
            SettingsGroup {
                ResetButton(title: "Reset the visualizer", keys: ["visualizer", "vizHeight", "vizPosition", "vizOffset", "vizSide", "vizOpacity", "vizBars", "vizGap", "vizRound", "vizColor", "vizBoost", "vizLyrics", "vizSong", "vizArtist"]) { Player.shared.refreshAnalysis() }
            }
        }
        .onChange(of: visualizer) { _ in Player.shared.refreshAnalysis() }
    }
}

// MARK: - Settings > Lyrics

struct LyricsSettings: View {
    @AppStorage("lyricsWords") private var lyricsWords = true
    @AppStorage("censorLyrics") private var censorLyrics = false
    @AppStorage("lyricsSize") private var size = 34.0
    @AppStorage("lyricsSpacing") private var spacing = 14.0
    @AppStorage("lyricsWidth") private var width = 720.0
    @AppStorage("lyricsAnchor") private var anchor = 0.35
    @AppStorage("lyricsFloor") private var floor = 0.16
    @AppStorage("lyricsCurve") private var curve = 1.0

    var body: some View {
        SettingsPage {
            SettingsGroup("Reading") {
                SettingToggle(title: "Light up lyrics word by word", help: "Uses the word timings when a file has them, or the timing Strata works out itself.", isOn: $lyricsWords)
                SettingToggle(title: "Hide bad words in lyrics", isOn: $censorLyrics)
            }
            SettingsGroup("Size and spacing") {
                SliderRow(title: "Text size", value: $size, range: 20...56, step: 1, standard: 34)
                SliderRow(title: "Space between lines", value: $spacing, range: 2...48, step: 1, standard: 14, unit: " pt")
                SliderRow(title: "Width of the lyrics", help: "Longer lines wrap at this width.", value: $width, range: 360...1100, step: 10, standard: 720, unit: " pt")
            }
            SettingsGroup("The wheel") {
                SliderRow(title: "Where the sung line sits", help: "Higher puts it nearer the top of the page.", value: $anchor, range: 0.15...0.65, standard: 0.35, unit: "%", scale: 100)
                SliderRow(title: "How dim the other lines are", help: "Lines far from the sung one fade down to this brightness.", value: $floor, range: 0.04...0.7, standard: 0.16, unit: "%", scale: 100)
                SliderRow(title: "Curve", help: "How much the lines shrink and turn away from the sung one. 0 keeps them flat.", value: $curve, range: 0...2, standard: 1, unit: "%", scale: 100)
            }
            WordSyncSection()
            SettingsGroup {
                ResetButton(title: "Reset the lyrics look", keys: ["lyricsWords", "censorLyrics", "lyricsSize", "lyricsSpacing", "lyricsWidth", "lyricsAnchor", "lyricsFloor", "lyricsCurve"])
            }
        }
    }
}
