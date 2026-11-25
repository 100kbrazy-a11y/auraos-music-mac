import SwiftUI
import AppKit

/// picks the app for this macOS: macOS 13 and later get every window and the menu bar item as SwiftUI scenes; macOS 12 has no scenes for
/// those (no Window, no MenuBarExtra, no openWindow), so they are built by hand there (see Compat.swift)
@main
@MainActor
enum Launcher {
    static func main() {
        // scroll bars appear only while you scroll, whatever the Mac's own setting (this applies to Strata alone)
        UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
        if #available(macOS 13, *) { StrataApp.main() } else { StrataApp12.main() }
    }
}

/// the library window, as both apps build it
@MainActor
func strataMain(lib: Library, player: Player, updater: Updater) -> some View {
    RootView()
        .environmentObject(lib)
        .environmentObject(player)
        .environmentObject(updater)
        .frame(minWidth: 980, minHeight: 640)
        .preferredColorScheme(.dark)
        .captureOpenWindow()
        .onAppear { LegacyMenuBar.startIfNeeded() }
        .onOpenURL { url in
            if url.scheme == "strata" { URLCommands.handle(url, lib: lib, player: player) }
            else { lib.importURLs([url], thenPlay: true) }
        }
        .task {
            // when the app opens, then every few hours while it stays open
            while !Task.isCancelled {
                if UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true { await updater.check(silent: true) }
                try? await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000)
            }
        }
}

/// the menus (the same on every macOS); [open] opens a window by name
@MainActor @CommandsBuilder
func strataCommands(lib: Library, player: Player, updater: Updater, open: @escaping (String) -> Void) -> some Commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await updater.check() } }
            }
            CommandGroup(after: .textEditing) {
                Button("Search") { NotificationCenter.default.post(name: .focusSearch, object: nil) }.keyboardShortcut("f")
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Music…") { lib.pickMusic() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") { open("shortcuts") }.keyboardShortcut("/", modifiers: .command)
            }
            CommandMenu("Playback") {
                Button(player.isPlaying ? "Pause" : "Play") { player.togglePlay() }.keyboardShortcut(.space, modifiers: [])
                Button("Skip Back 10 Seconds") { player.seek(to: max(0, player.clock.position - 10)) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("Skip Forward 10 Seconds") { player.seek(to: min(player.duration, player.clock.position + 10)) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Divider()
                Button("Next Song") { player.next() }.keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Previous Song") { player.previous() }.keyboardShortcut(.leftArrow, modifiers: .command)
                Divider()
                Button("Volume Up") { player.volume = min(1, player.volume + 0.1) }.keyboardShortcut(.upArrow, modifiers: .command)
                Button("Volume Down") { player.volume = max(0, player.volume - 0.1) }.keyboardShortcut(.downArrow, modifiers: .command)
                Divider()
                Button(player.shuffle ? "Turn Shuffle Off" : "Turn Shuffle On") { player.shuffle.toggle() }.keyboardShortcut("s", modifiers: [.command, .option])
                Button("Change Repeat") { player.cycleRepeat() }.keyboardShortcut("r", modifiers: [.command, .option])
                Divider()
                Button("Show Player") { NotificationCenter.default.post(name: .openPlayer, object: nil) }.keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Lyrics") { NotificationCenter.default.post(name: .openPlayer, object: nil); NotificationCenter.default.post(name: .playerPage, object: 0) }.keyboardShortcut("l", modifiers: [.command, .option])
                Button("Up Next") { NotificationCenter.default.post(name: .toggleQueue, object: nil) }.keyboardShortcut("u", modifiers: .command)
                Button("Show Current Song's Album") { NotificationCenter.default.post(name: .jumpCurrent, object: nil) }.keyboardShortcut("j", modifiers: .command)
                Button("Mini Player") { Presence.toggleMini { open("mini") } }.keyboardShortcut("m", modifiers: [.command, .option])
                Button("Desktop Lyrics") { Presence.toggleDesktopLyrics { open("desktoplyrics") } }.keyboardShortcut("d", modifiers: [.command, .option])
                Divider()
                Button(player.current.map { lib.isFav($0) } == true ? "Remove from Favorites" : "Add to Favorites") { if let s = player.current { lib.toggleFav(s) } }.keyboardShortcut("l", modifiers: .command)
                Button("Start Radio from This Song") { if let s = player.current { Radio.shared.start(from: s) } }
            }
        
}

// MARK: - macOS 13 and later

@available(macOS 13, *)
struct StrataApp: App {
    @StateObject private var lib = Library()
    @StateObject private var player = Player.shared
    @StateObject private var updater = Updater()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @AppStorage("menuBar") private var menuBar = true

    var body: some Scene {
        WindowGroup(id: "main") {
            strataMain(lib: lib, player: player, updater: updater)
        }
        .commands { strataCommands(lib: lib, player: player, updater: updater, open: { openWindow(id: $0) }) }
        MenuBarExtra(isInserted: $menuBar) {
            MenuBarPlayer().environmentObject(lib).environmentObject(player).captureOpenWindow()
        } label: {
            Image(systemName: player.isPlaying ? "waveform" : "music.note")
        }
        .menuBarExtraStyle(.window)
        Window("Mini Player", id: "mini") {
            MiniPlayerView().environmentObject(lib).environmentObject(player)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 340, height: 78)
        Window("Desktop Lyrics", id: "desktoplyrics") {
            DesktopLyricsView().environmentObject(player)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 560, height: 110)
        Window("Keyboard Shortcuts", id: "shortcuts") {
            ShortcutsView()
        }
        .windowResizability(.contentSize)
        Settings {
            SettingsView().environmentObject(lib).environmentObject(updater)
        }
    }
}

// MARK: - macOS 12

struct StrataApp12: App {
    @StateObject private var lib = Library()
    @StateObject private var player = Player.shared
    @StateObject private var updater = Updater()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            strataMain(lib: lib, player: player, updater: updater)
        }
        .commands { strataCommands(lib: lib, player: player, updater: updater, open: { AppWindows.open($0) }) }
        Settings {
            SettingsView().environmentObject(lib).environmentObject(updater)
        }
    }
}
