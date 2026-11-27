import SwiftUI
import AppKit

// MARK: - colours

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        var v: UInt64 = 0
        Scanner(string: h).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }
    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.systemPurple
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
}

enum Look {
    /// the player's colour: the cover's, or the one you picked
    static func accent(for s: Song?) -> Color {
        if UserDefaults.standard.string(forKey: "accentMode") == "fixed" {
            return Color(hex: UserDefaults.standard.string(forKey: "accentHex") ?? "#9E80FF")
        }
        return Covers.accent(s)
    }
}

// MARK: - seasons

enum Season: String, CaseIterable, Identifiable {
    case auto, autumn, winter, spring, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Automatic (follows the date)"
        case .autumn: return "Autumn leaves"
        case .winter: return "Winter snow"
        case .spring: return "Spring petals"
        case .off: return "Off"
        }
    }
    static func forDate(_ d: Date) -> Season {
        switch Calendar.current.component(.month, from: d) {
        case 9, 10, 11: return .autumn
        case 12, 1, 2: return .winter
        case 3, 4, 5: return .spring
        default: return .off
        }
    }
    /// what to draw right now (nil = nothing). [raw] is the saved choice; "" means the old on/off leaves switch decides.
    static func resolve(_ raw: String, legacyLeaves: Bool) -> Season? {
        var s = Season(rawValue: raw) ?? (legacyLeaves ? .autumn : .off)
        if s == .auto { s = forDate(Date()) }
        return s == .off ? nil : s
    }
}

private struct SeededGen: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
}

/// whichever effect is chosen. Clock-based like the leaves, so the library's copy and the player's copy line up and nothing restarts.
struct SeasonEffect: View {
    var kind: Season
    var area: CGSize? = nil
    var body: some View {
        switch kind {
        case .autumn: FallingLeaves(area: area)
        case .winter: SnowFall(area: area)
        case .spring: PetalFall(area: area)
        default: EmptyView()
        }
    }
}

/// the library's copy of the effect: the same picture as the player's, cut out where this page sits in the window
struct DetailEffect: View {
    var window: CGRect
    var kind: Season
    var body: some View {
        GeometryReader { g in
            let f = g.frame(in: .global)
            SeasonEffect(kind: kind, area: window.size)
                .frame(width: window.width, height: window.height, alignment: .topLeading)
                .offset(x: window.minX - f.minX, y: window.minY - f.minY)
                .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
                .clipped()
        }
        .allowsHitTesting(false)
    }
}

struct SnowFall: View {
    var area: CGSize? = nil
    @ObservedObject private var act = AppActive.shared
    private struct Flake { var x: Double; var speed: Double; var size: Double; var phase: Double; var sway: Double; var alpha: Double }
    private static let flakes: [Flake] = {
        var g = SeededGen(state: 77)
        return (0..<70).map { _ in
            Flake(x: Double.random(in: 0...1, using: &g), speed: Double.random(in: 22...60, using: &g), size: Double.random(in: 1.4...4.2, using: &g),
                  phase: Double.random(in: 0...1, using: &g), sway: Double.random(in: 0.3...1.0, using: &g), alpha: Double.random(in: 0.45...0.9, using: &g))
        }
    }()
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !act.active)) { tl in
            Canvas(rendersAsynchronously: true) { ctx, canvasSize in
                let size = area ?? canvasSize
                let t = tl.date.timeIntervalSinceReferenceDate
                for f in Self.flakes {
                    let travel = Double(size.height) + 40
                    let cycle = travel / f.speed
                    let p = ((t + f.phase * cycle).truncatingRemainder(dividingBy: cycle)) / cycle
                    let y = -20 + p * travel
                    let x = f.x * Double(size.width) + sin(t * f.sway + f.phase * 6) * 24
                    ctx.fill(Path(ellipseIn: CGRect(x: x - f.size, y: y - f.size, width: f.size * 2, height: f.size * 2)), with: .color(.white.opacity(f.alpha)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct PetalFall: View {
    var area: CGSize? = nil
    @ObservedObject private var act = AppActive.shared
    private struct Petal { var x: Double; var speed: Double; var size: Double; var phase: Double; var sway: Double; var rot: Double; var spin: Double; var color: Color }
    private static let petals: [Petal] = {
        var g = SeededGen(state: 305)
        let palette: [Color] = [Color(red: 1.0, green: 0.74, blue: 0.82), Color(red: 0.98, green: 0.62, blue: 0.74), Color(red: 1.0, green: 0.86, blue: 0.90), Color(red: 0.95, green: 0.55, blue: 0.70)]
        return (0..<28).map { _ in
            Petal(x: Double.random(in: 0...1, using: &g), speed: Double.random(in: 30...65, using: &g), size: Double.random(in: 0.6...1.3, using: &g),
                  phase: Double.random(in: 0...1, using: &g), sway: Double.random(in: 0.6...1.6, using: &g), rot: Double.random(in: 0...6.28, using: &g),
                  spin: Double.random(in: -1.6...1.6, using: &g), color: palette[Int.random(in: 0..<palette.count, using: &g)])
        }
    }()
    private static let shape: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: -9))
        p.addCurve(to: CGPoint(x: 0, y: 9), control1: CGPoint(x: 9, y: -6), control2: CGPoint(x: 8, y: 5))
        p.addCurve(to: CGPoint(x: 0, y: -9), control1: CGPoint(x: -8, y: 5), control2: CGPoint(x: -9, y: -6))
        p.closeSubpath()
        return p
    }()
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !act.active)) { tl in
            Canvas(rendersAsynchronously: true) { ctx, canvasSize in
                let size = area ?? canvasSize
                let t = tl.date.timeIntervalSinceReferenceDate
                for l in Self.petals {
                    let travel = Double(size.height) + 100
                    let cycle = travel / l.speed
                    let p = ((t + l.phase * cycle).truncatingRemainder(dividingBy: cycle)) / cycle
                    let y = -50 + p * travel
                    let x = l.x * Double(size.width) + sin(t * l.sway + l.phase * 6) * 55
                    var c = ctx
                    c.translateBy(x: CGFloat(x), y: CGFloat(y))
                    c.rotate(by: .radians(l.rot + t * l.spin))
                    // a flutter: the petal narrows and widens as it turns
                    c.scaleBy(x: CGFloat(l.size * (0.55 + 0.45 * abs(sin(t * l.sway + l.phase * 9)))), y: CGFloat(l.size))
                    c.fill(Self.shape, with: .color(l.color.opacity(0.85)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - the player's background

struct PlayerBackdrop: View {
    var accent: Color
    var song: Song?
    @ObservedObject private var act = AppActive.shared
    @AppStorage("bgStyle") private var style = "aurora"

    var body: some View {
        switch style {
        case "cover":
            ZStack {
                Color.black
                SoftCover(song: song).scaleEffect(1.1)
                Color.black.opacity(0.42)
            }
            .clipped()
        case "plain":
            Color(red: 0.05, green: 0.05, blue: 0.06)
        case "gradient":
            TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: !act.active)) { tl in
                let a = tl.date.timeIntervalSinceReferenceDate * 0.06
                LinearGradient(colors: [accent.opacity(0.9), Color(red: 0.04, green: 0.04, blue: 0.06), accent.opacity(0.5)],
                               startPoint: UnitPoint(x: 0.5 + 0.5 * cos(a), y: 0.5 + 0.5 * sin(a)),
                               endPoint: UnitPoint(x: 0.5 - 0.5 * cos(a), y: 0.5 - 0.5 * sin(a)))
            }
        default:
            AuroraBackground(color: accent)
        }
    }
}

// MARK: - Settings > Look

struct LookSettings: View {
    @AppStorage("accentMode") private var accentMode = "cover"
    @AppStorage("accentHex") private var accentHex = "#9E80FF"
    @AppStorage("bgStyle") private var bgStyle = "aurora"
    @AppStorage("glassTint") private var glassTint = 1.0
    @AppStorage("barRadius") private var barRadius = 26.0
    @AppStorage("listCover") private var listCover = 34.0
    @AppStorage("season") private var season = ""
    @AppStorage("leaves") private var legacyLeaves = true
    @AppStorage("songsLayout") private var songsLayout = "table"
    @AppStorage("appIcon") private var appIcon = "original"
    @AppStorage("effects") private var effects = "full"

    private let swatches = ["#9E80FF", "#FF5E7E", "#FF8A3D", "#F5C542", "#4FD18B", "#3FC1E8", "#4C7DFF", "#C2C2CC"]

    var body: some View {
        SettingsPage {
            SettingsGroup("Colours") {
                SettingChoice(title: "Accent colour", selection: $accentMode, options: [("cover", "From the cover"), ("fixed", "Always the same")])
                    .onChange(of: accentMode) { _ in Player.shared.refreshAccent() }
                if accentMode == "fixed" {
                    HStack(spacing: 8) {
                        ForEach(swatches, id: \.self) { h in
                            Circle().fill(Color(hex: h)).frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(.white, lineWidth: accentHex.uppercased() == h ? 2 : 0))
                                .onTapGesture { accentHex = h; Player.shared.refreshAccent() }
                        }
                        ColorPicker("", selection: Binding(get: { Color(hex: accentHex) }, set: { accentHex = $0.hexString; Player.shared.refreshAccent() }), supportsOpacity: false).labelsHidden()
                    }
                }
                SettingMenu("Player background", selection: $bgStyle) {
                    Text("Aurora").tag("aurora")
                    Text("Blurred cover").tag("cover")
                    Text("Moving gradient").tag("gradient")
                    Text("Plain").tag("plain")
                }
            }
            SettingsGroup("Glass") {
                SliderRow(title: "Colour in the glass", value: $glassTint, range: 0...1, standard: 1, unit: "%", scale: 100)
                SliderRow(title: "Media bar corners", value: $barRadius, range: 12...34, step: 1, standard: 26)
                SettingNote("The glass look itself comes from macOS 26. On older macOS you get the frosted version.")
            }
            SettingsGroup("Seasons and effects") {
                SettingMenu("Falling effect", selection: Binding(get: { season.isEmpty ? (legacyLeaves ? "autumn" : "off") : season }, set: { season = $0 })) {
                    ForEach(Season.allCases) { Text($0.label).tag($0.rawValue) }
                }
                SettingChoice(title: "Animated effects", help: "Light turns off the falling effect. It is also off in Low Power Mode, while the window is hidden, and while macOS Reduce Motion is on. It is always behind the text.", selection: $effects, options: [("full", "Full"), ("light", "Light")])
            }
            SettingsGroup("Lists") {
                SettingChoice(title: "Songs layout", selection: $songsLayout, options: [("table", "Table"), ("list", "List")])
                SliderRow(title: "Cover size in lists", value: $listCover, range: 24...60, step: 2, standard: 34, unit: " pt")
            }
            SettingsGroup("App icon") {
                HStack(spacing: 10) {
                    ForEach(AppIcons.variants) { v in
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(LinearGradient(colors: [Color(red: v.dark.0, green: v.dark.1, blue: v.dark.2), Color(red: v.dark.0 * 0.6, green: v.dark.1 * 0.6, blue: v.dark.2 * 0.6)], startPoint: .top, endPoint: .bottom))
                                .overlay(Image(systemName: "music.note").foregroundStyle(Color(red: v.light.0, green: v.light.1, blue: v.light.2)))
                                .frame(width: 40, height: 40)
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white, lineWidth: appIcon == v.id ? 2 : 0))
                            Text(v.name).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        .onTapGesture { appIcon = v.id; AppIcons.apply(v.id) }
                    }
                }
                SettingNote("Changes the Dock icon while Strata is open. macOS keeps showing the app file's own icon when it's closed.")
            }
            SettingsGroup {
                ResetButton(title: "Reset colours, glass and lists", keys: ["accentMode", "accentHex", "bgStyle", "glassTint", "barRadius", "listCover", "season", "songsLayout", "effects"]) { Player.shared.refreshAccent() }
            }
        }
    }
}
