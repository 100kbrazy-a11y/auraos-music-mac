import SwiftUI
import AppKit
import Combine

// Everything here exists so that Strata Music also runs on macOS 12 (Monterey). Where macOS 13 or later has a better tool, it is used
// exactly as before; macOS 12 gets a plainer replacement that does the same job.

// MARK: - opening windows

/// macOS 13 can open a window by name from SwiftUI; macOS 12 cannot, so those windows are built by hand there
@MainActor
enum AppWindows {
    /// filled in by the library window (and the menu bar player) on macOS 13 and later
    static var openScene: ((String) -> Void)?

    static func open(_ id: String) {
        if let o = openScene { o(id) } else { LegacyWindows.open(id) }
    }
}

@available(macOS 13, *)
private struct CaptureOpenWindow: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content.onAppear { AppWindows.openScene = { id in openWindow(id: id) } }
    }
}

extension View {
    /// lets a modifier chain pick a different shape of view partway (used for things that differ by macOS version)
    func apply<V: View>(@ViewBuilder _ f: (Self) -> V) -> V { f(self) }

    /// remembers SwiftUI's "open a window" action so `AppWindows.open` can use it (macOS 13 and later; nothing on macOS 12)
    @ViewBuilder func captureOpenWindow() -> some View {
        if #available(macOS 13, *) { self.modifier(CaptureOpenWindow()) } else { self }
    }
}

/// the mini player, the desktop lyrics and the shortcut list as plain windows (used on macOS 12)
@MainActor
enum LegacyWindows {
    private static var windows: [String: NSWindow] = [:]

    static func open(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        if id == "main" { reopenMain(); return }
        if let w = windows[id] {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
            return
        }
        guard let lib = Library.main else { return }
        let root: AnyView
        let title: String
        var size = NSSize(width: 340, height: 78)
        var minSize = NSSize(width: 300, height: 78)
        var resizable = true
        switch id {
        case "mini":
            title = "Mini Player"
            root = AnyView(MiniPlayerView().environmentObject(lib).environmentObject(Player.shared))
        case "desktoplyrics":
            title = "Desktop Lyrics"
            size = NSSize(width: 560, height: 110); minSize = NSSize(width: 300, height: 60)
            root = AnyView(DesktopLyricsView().environmentObject(Player.shared))
        case "shortcuts":
            title = "Keyboard Shortcuts"
            root = AnyView(ShortcutsView()); resizable = false
        default:
            return
        }
        let host = NSHostingController(rootView: root)
        let w = NSWindow(contentViewController: host)
        w.title = title
        w.styleMask = resizable ? [.titled, .closable, .miniaturizable, .resizable] : [.titled, .closable, .miniaturizable]
        w.isReleasedWhenClosed = false
        if resizable { w.setContentSize(size); w.contentMinSize = minSize }
        else { w.setContentSize(host.view.fittingSize) }
        w.center()
        windows[id] = w
        w.makeKeyAndOrderFront(nil)
    }

    private static func reopenMain() {
        if let w = Presence.mainWindow {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
            return
        }
        // the library window was closed: ask the app for a new one
        if !NSApp.sendAction(Selector(("newWindowForTab:")), to: nil, from: nil) { NSWorkspace.shared.open(Bundle.main.bundleURL) }
    }
}

// MARK: - the menu bar player on macOS 12 (macOS 13 has MenuBarExtra)

@MainActor
final class LegacyMenuBar: NSObject {
    static let shared = LegacyMenuBar()
    private var item: NSStatusItem?
    private var popover: NSPopover?
    private var bag = Set<AnyCancellable>()
    private var started = false

    /// starts the menu bar player where the system has no MenuBarExtra
    static func startIfNeeded() {
        if #available(macOS 13, *) { return }
        shared.start()
    }

    private var wanted: Bool { UserDefaults.standard.object(forKey: "menuBar") as? Bool ?? true }

    private func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.sync() }.store(in: &bag)
        Player.shared.objectWillChange
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.icon() }.store(in: &bag)
        sync()
    }

    private func sync() {
        if wanted, item == nil {
            let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            it.button?.target = self
            it.button?.action = #selector(toggle(_:))
            item = it
            icon()
        } else if !wanted, let it = item {
            popover?.close()
            NSStatusBar.system.removeStatusItem(it)
            item = nil
        }
    }

    private func icon() {
        guard let b = item?.button else { return }
        let img = NSImage(systemSymbolName: Player.shared.isPlaying ? "waveform" : "music.note", accessibilityDescription: "Strata Music")
        img?.isTemplate = true
        if b.image != img { b.image = img }
    }

    @objc private func toggle(_ sender: Any?) {
        guard let b = item?.button, let lib = Library.main else { return }
        if let p = popover, p.isShown { p.performClose(nil); return }
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = NSHostingController(rootView: MenuBarPlayer().environmentObject(lib).environmentObject(Player.shared))
        popover = p
        NSApp.activate(ignoringOtherApps: true)
        p.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
    }
}

// MARK: - going into an album or an artist

/// where you are inside a page (album, artist…). macOS 13 and later keep it in a NavigationPath; macOS 12 has no such thing, so a plain list is used there
struct AppPath {
    private(set) var legacy: [AnyHashable] = []
    private var store: Any?

    @available(macOS 13, *)
    var modern: NavigationPath {
        get { (store as? NavigationPath) ?? NavigationPath() }
        set { store = newValue }
    }

    var isEmpty: Bool {
        if #available(macOS 13, *) { return modern.isEmpty }
        return legacy.isEmpty
    }

    mutating func reset() { store = nil; legacy = [] }

    mutating func removeLast() {
        if #available(macOS 13, *) { var p = modern; if !p.isEmpty { p.removeLast() }; modern = p }
        else { _ = legacy.popLast() }
    }

    mutating func append<V: Hashable>(_ v: V) {
        if #available(macOS 13, *) { var p = modern; p.append(v); modern = p }
        else { legacy.append(AnyHashable(v)) }
    }
}

private struct LegacyPushKey: EnvironmentKey { static let defaultValue: ((AnyHashable) -> Void)? = nil }
extension EnvironmentValues {
    var legacyPush: ((AnyHashable) -> Void)? {
        get { self[LegacyPushKey.self] }
        set { self[LegacyPushKey.self] = newValue }
    }
}

/// a link that opens another page (NavigationLink on macOS 13 and later, a button that pushes onto the list on macOS 12)
struct NavLink<V: Hashable, Label: View>: View {
    let value: V
    let label: () -> Label
    @Environment(\.legacyPush) private var push

    init(value: V, @ViewBuilder label: @escaping () -> Label) { self.value = value; self.label = label }

    var body: some View {
        if #available(macOS 13, *) {
            NavigationLink(value: value, label: label)
        } else {
            Button { push?(AnyHashable(value)) } label: { label() }.buttonStyle(.plain)
        }
    }
}

/// macOS 12's stand-in for NavigationStack: the page you are on sits under the pages you went into
struct LegacyStack<Root: View>: View {
    @Binding var path: AppPath
    let root: Root

    private var top: AnyHashable? { path.legacy.last }

    var body: some View {
        ZStack {
            root.opacity(top == nil ? 1 : 0).allowsHitTesting(top == nil)
            if let t = top { destination(t).id(path.legacy.count).transition(.identity) }
        }
        .environment(\.legacyPush, { path.append($0) })
    }

    @ViewBuilder private func destination(_ v: AnyHashable) -> some View {
        if let a = v.base as? AlbumRef { AlbumDetail(key: a.key) }
        else if let a = v.base as? ArtistRef { ArtistDetail(name: a.name) }
        else if let c = v.base as? YtCollection { YtCollectionView(c: c) }
        else if let a = v.base as? YtArtistRef { YtArtistView(a: a) }
        else { EmptyView() }
    }
}

// MARK: - small look-alikes for things macOS 13 added

extension View {
    /// a grouped settings form; macOS 12 keeps its own form look
    @ViewBuilder func groupedForm(clearBackground: Bool = false) -> some View {
        if #available(macOS 13, *) {
            if clearBackground { self.formStyle(.grouped).scrollContentBackground(.hidden) } else { self.formStyle(.grouped) }
        } else {
            if clearBackground { self.clearScrollBackground() } else { self }
        }
    }

    /// makes a settings page scroll. On macOS 13 and later a grouped Form scrolls by itself; on macOS 12 a Form is a plain stack that
    /// just runs off the bottom of the window, so there it goes in a ScrollView.
    @ViewBuilder func settingsPage() -> some View {
        if #available(macOS 13, *) { self }
        else { ScrollView(.vertical) { self.padding(20) } }
    }

    @ViewBuilder func columnsForm() -> some View {
        if #available(macOS 13, *) { self.formStyle(.columns) } else { self }
    }

    /// lets the window's own background show through a list, table or form
    @ViewBuilder func clearScrollBackground() -> some View {
        if #available(macOS 13, *) { self.scrollContentBackground(.hidden) } else { self.background(ClearScrollBacking()) }
    }

    @ViewBuilder func hideMenuIndicator() -> some View {
        if #available(macOS 13, *) { self.menuIndicator(.hidden) } else { self }
    }
}

/// finds the scroll view next to it and makes its background see-through (what scrollContentBackground(.hidden) does on macOS 13)
struct ClearScrollBacking: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let parent = v.superview else { return }
            func find(_ view: NSView, _ depth: Int) -> NSScrollView? {
                if let s = view as? NSScrollView { return s }
                if depth == 0 { return nil }
                for c in view.subviews { if let s = find(c, depth - 1) { return s } }
                return nil
            }
            if let sv = find(parent, 4) {
                sv.drawsBackground = false
                sv.backgroundColor = .clear
                if let t = sv.documentView as? NSTableView { t.backgroundColor = .clear }
            }
        }
    }
}

/// LabeledContent on macOS 13 and later; a plain row with the title on the left on macOS 12
struct CompatLabeled<Content: View>: View {
    let title: String
    let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) { self.title = title; self.content = content }

    var body: some View {
        if #available(macOS 13, *) {
            LabeledContent(title, content: content)
        } else {
            HStack { Text(title); Spacer(); content() }
        }
    }
}

extension CompatLabeled where Content == Text {
    init(_ title: String, value: String) { self.init(title) { Text(value).foregroundColor(.secondary) } }
}

// MARK: - a picture of a view

/// draws a view into an image (ImageRenderer on macOS 13 and later, a hidden hosting view on macOS 12)
@MainActor
func renderNSImage<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> NSImage? {
    let sized = view.frame(width: width, height: height)
    if #available(macOS 13, *) {
        let r = ImageRenderer(content: sized)
        r.scale = 1
        return r.nsImage
    }
    let host = NSHostingView(rootView: sized)
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: rep)
    let img = NSImage(size: host.bounds.size)
    img.addRepresentation(rep)
    return img
}

// MARK: - words that wrap onto new lines

/// the lit lyric words, wrapped like text. macOS 13 and later use the Layout above; macOS 12 uses the older alignment-guide way.
struct WordFlow<Content: View>: View {
    var lineSpacing: CGFloat
    var count: Int
    let content: (Int) -> Content

    init(lineSpacing: CGFloat, count: Int, @ViewBuilder content: @escaping (Int) -> Content) {
        self.lineSpacing = lineSpacing; self.count = count; self.content = content
    }

    var body: some View {
        if #available(macOS 13, *) {
            FlowLayout(lineSpacing: lineSpacing) { ForEach(0..<count, id: \.self) { content($0) } }
        } else {
            LegacyFlow(lineSpacing: lineSpacing, count: count, content: content)
        }
    }
}

private struct FlowHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct LegacyFlow<Content: View>: View {
    let lineSpacing: CGFloat
    let count: Int
    let content: (Int) -> Content
    @State private var height: CGFloat = 0

    var body: some View {
        GeometryReader { g in flow(g.size.width) }
            .frame(height: height)
            .onPreferenceChange(FlowHeightKey.self) { height = $0 }
    }

    private func flow(_ width: CGFloat) -> some View {
        var x: CGFloat = 0
        var y: CGFloat = 0
        let n = count
        let gap = lineSpacing
        return ZStack(alignment: .topLeading) {
            ForEach(0..<n, id: \.self) { i in
                content(i)
                    .alignmentGuide(.leading) { d in
                        if abs(x - d.width) > width { x = 0; y -= d.height + gap }
                        let r = x
                        if i == n - 1 { x = 0 } else { x -= d.width }
                        return r
                    }
                    .alignmentGuide(.top) { _ in
                        let r = y
                        if i == n - 1 { y = 0 }
                        return r
                    }
            }
        }
        .background(GeometryReader { g in Color.clear.preference(key: FlowHeightKey.self, value: g.size.height) })
    }
}
