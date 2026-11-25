import SwiftUI
import AppKit
import Combine
import UserNotifications

extension Notification.Name {
    static let toggleQueue = Notification.Name("strata.toggleQueue")
    static let jumpCurrent = Notification.Name("strata.jumpCurrent")
}

/// small facts about the windows, shared by the menu bar, the mini player and the menus
@MainActor
enum Presence {
    static var playerOpen = false

    static var mainWindow: NSWindow? { NSApp.windows.first { $0.frameAutosaveName == "StrataMainWindow" } }
    static var miniWindow: NSWindow? { NSApp.windows.first { $0.identifier?.rawValue == "StrataMini" } }

    /// brings the library window forward (or asks for a new one when it was closed)
    static func showMain(open: () -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        if let w = mainWindow {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else { open() }
    }

    static var desktopWindow: NSWindow? { NSApp.windows.first { $0.identifier?.rawValue == "StrataDesktopLyrics" } }

    static func toggleDesktopLyrics(open: () -> Void) {
        if let w = desktopWindow, w.isVisible { w.close() } else { open() }
    }

    static func toggleMini(open: () -> Void) {
        if let w = miniWindow, w.isVisible { w.close() } else { open() }
    }
}

// MARK: - the menu bar player

struct MenuBarPlayer: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var lib: Library
    @AppStorage("menuLyrics") private var menuLyrics = true

    var body: some View {
        VStack(spacing: 12) {
            if let s = player.current {
                HStack(spacing: 12) {
                    CoverView(song: s, size: 64, radius: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                        Text(s.shownArtist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        if !s.album.isEmpty { Text(s.album).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1) }
                    }
                    Spacer(minLength: 4)
                    Button { lib.toggleFav(s) } label: { Image(systemName: lib.isFav(s) ? "heart.fill" : "heart").foregroundStyle(lib.isFav(s) ? player.accent : Color.secondary) }.buttonStyle(.plain)
                }
                SeekBar(clock: player.clock, duration: s.duration) { player.seek(to: $0) }
                TransportButtons().frame(maxWidth: .infinity)
                if menuLyrics { MenuBarLine(clock: player.clock, song: s) }
                let upcoming = Array(player.queue.enumerated()).filter { $0.offset > player.index }.prefix(4)
                if !upcoming.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("UP NEXT").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        ForEach(Array(upcoming), id: \.offset) { i, q in
                            Button { player.jump(to: i) } label: {
                                HStack(spacing: 8) {
                                    CoverView(song: q, size: 26, radius: 5)
                                    Text(q.title).font(.system(size: 12)).lineLimit(1)
                                    Spacer()
                                    Text(q.shownArtist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("Nothing is playing").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            Divider()
            HStack {
                Button("Open Strata Music") { Presence.showMain { AppWindows.open("main") } }
                Button("Mini Player") { Presence.toggleMini { AppWindows.open("mini") } }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(14).frame(width: 320)
    }
}

// MARK: - the mini player

struct MiniPlayerView: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var lib: Library
    @AppStorage("miniOnTop") private var onTop = true

    var body: some View {
        GeometryReader { g in
            let compact = g.size.height < 150
            ZStack {
                SoftCover(song: player.current).frame(width: g.size.width, height: g.size.height).clipped()
                Rectangle().fill(.ultraThinMaterial)
                if let s = player.current {
                    if compact { strip(s, g.size) } else { square(s, g.size) }
                } else {
                    Text("Nothing is playing").foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 300, minHeight: 78)
        .preferredColorScheme(.dark)
        .contextMenu {
            Toggle("Keep on Top", isOn: $onTop)
            Button("Open Strata Music") { Presence.showMain { AppWindows.open("main") } }
            Button("Close") { Presence.miniWindow?.close() }
        }
        .background(WindowAccessor { w in
            w.identifier = NSUserInterfaceItemIdentifier("StrataMini")
            w.title = "Mini Player"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.level = onTop ? .floating : .normal
            w.standardWindowButton(.miniaturizeButton)?.isHidden = true
            w.standardWindowButton(.zoomButton)?.isHidden = true
            w.collectionBehavior.insert(.fullScreenAuxiliary)
            _ = w.setFrameAutosaveName("StrataMiniWindow")
        })
    }

    private func strip(_ s: Song, _ size: CGSize) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 12) {
                CoverView(song: s, size: 50, radius: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(s.shownArtist).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                TransportButtons()
            }
            .padding(.horizontal, 14).padding(.top, 14)
            SeekBar(clock: player.clock, duration: s.duration) { player.seek(to: $0) }.padding(.horizontal, 14).padding(.bottom, 6)
        }
    }

    private func square(_ s: Song, _ size: CGSize) -> some View {
        let side = max(80, min(size.width - 40, size.height - 150))
        return VStack(spacing: 10) {
            CoverView(song: s, size: side, radius: 14).shadow(color: .black.opacity(0.4), radius: 14, y: 8).padding(.top, 26)
            VStack(spacing: 2) {
                Text(s.title).font(.system(size: 15, weight: .bold)).lineLimit(1)
                Text(s.shownArtist).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            SeekBar(clock: player.clock, duration: s.duration) { player.seek(to: $0) }.padding(.horizontal, 20)
            HStack(spacing: 22) {
                Button { lib.toggleFav(s) } label: { Image(systemName: lib.isFav(s) ? "heart.fill" : "heart").foregroundStyle(lib.isFav(s) ? player.accent : Color.secondary) }.buttonStyle(.plain)
                TransportButtons()
                QueueButton(scope: .none).foregroundStyle(.secondary)
            }
            .padding(.bottom, 14)
        }
    }
}

// MARK: - the shortcuts sheet (⌘/)

struct ShortcutsView: View {
    private let groups: [(String, [(String, String)])] = [
        ("Playback", [("Play / Pause", "Space"), ("Next / Previous", "⌘→  ⌘←"), ("Skip 10 seconds", "⌥⌘→  ⌥⌘←"), ("Volume", "⌘↑  ⌘↓"),
                      ("Shuffle", "⌥⌘S"), ("Repeat", "⌥⌘R"), ("Like the current song", "⌘L")]),
        ("Windows", [("Show the player", "⇧⌘L"), ("Lyrics", "⌥⌘L"), ("Up Next", "⌘U"), ("Mini player", "⌥⌘M"), ("Desktop lyrics", "⌥⌘D"), ("Show the current song's album", "⌘J"), ("Close the player", "Esc")]),
        ("Library", [("Search", "⌘F"), ("Add music", "⌘O"), ("Move through a list", "↑  ↓"), ("Play the selected song", "Return"), ("Jump to a title", "Start typing")]),
        ("Search drop-down", [("Move through results", "↑  ↓"), ("Open the highlighted result", "Return"), ("Search YouTube for what you typed", "Return, with nothing highlighted"), ("Close", "Esc")]),
    ]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(groups, id: \.0) { g in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(g.0).font(.system(size: 13, weight: .bold)).foregroundStyle(.secondary).textCase(.uppercase)
                        ForEach(g.1, id: \.0) { r in
                            HStack { Text(r.0); Spacer(); Text(r.1).font(.system(size: 13, design: .rounded)).foregroundStyle(.secondary) }
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
            .padding(24)
        }
        .frame(width: 440, height: 520)
        .preferredColorScheme(.dark)
    }
}

// MARK: - the Dock menu and song notifications

private final class ClosureItem: NSMenuItem {
    var block: (() -> Void)?
    convenience init(_ title: String, _ block: @escaping () -> Void) {
        self.init(title: title, action: #selector(run), keyEquivalent: "")
        self.block = block; target = self
    }
    @objc func run() { block?() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var songWatcher: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let crashed = CrashGuard.begin()
        HangWatch.start()
        MusicPack.cleanup()
        AppIcons.applySaved()
        if crashed { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Diagnostics.askAfterCrash() } }
        songWatcher = Player.shared.$current.dropFirst().removeDuplicates { $0?.id == $1?.id }.sink { song in
            Task { @MainActor in Notifier.songChanged(song) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Library.main?.saveNow()
        PlayLog.shared.flush()
        CrashGuard.end()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let p = Player.shared
        let m = NSMenu()
        if let s = p.current {
            let head = NSMenuItem(title: s.title + " · " + s.shownArtist, action: nil, keyEquivalent: "")
            head.isEnabled = false
            m.addItem(head)
            m.addItem(.separator())
        }
        m.addItem(ClosureItem(p.isPlaying ? "Pause" : "Play") { Player.shared.togglePlay() })
        m.addItem(ClosureItem("Next") { Player.shared.next() })
        m.addItem(ClosureItem("Previous") { Player.shared.previous() })
        if let s = p.current, let lib = Library.main {
            m.addItem(.separator())
            m.addItem(ClosureItem(lib.isFav(s) ? "Remove from Favorites" : "Add to Favorites") { lib.toggleFav(s) })
        }
        return m
    }
}

enum Notifier {
    static func authorize() { UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in } }

    /// a banner when the song changes while the app is in the background (optional)
    @MainActor static func songChanged(_ s: Song?) {
        guard UserDefaults.standard.bool(forKey: "notifySong"), let s = s, !NSApp.isActive else { return }
        let c = UNMutableNotificationContent()
        c.title = s.title
        c.body = [s.shownArtist, s.album].filter { !$0.isEmpty }.joined(separator: " · ")
        if let u = Covers.url(s) {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("strata-cover-\(s.cover).jpg")
            if !FileManager.default.fileExists(atPath: tmp.path) { try? FileManager.default.copyItem(at: u, to: tmp) }
            if let a = try? UNNotificationAttachment(identifier: "cover", url: tmp, options: [UNNotificationAttachmentOptionsTypeHintKey: "public.jpeg"]) { c.attachments = [a] }
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "strata.song", content: c, trigger: nil))
    }
}
