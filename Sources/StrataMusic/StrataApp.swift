import SwiftUI
import AppKit

@main
struct StrataApp: App {
    @StateObject private var lib = Library()
    @StateObject private var player = Player.shared
    @StateObject private var updater = Updater()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(lib)
                .environmentObject(player)
                .environmentObject(updater)
                .frame(minWidth: 980, minHeight: 640)
                .preferredColorScheme(.dark)
                .onOpenURL { url in lib.importURLs([url], thenPlay: true) }
                .task {
                    // when the app opens, then every few hours while it stays open
                    while !Task.isCancelled {
                        if UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true { await updater.check(silent: true) }
                        try? await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000)
                    }
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await updater.check() } }
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Music…") { lib.pickMusic() }.keyboardShortcut("o")
            }
            CommandMenu("Playback") {
                Button(player.isPlaying ? "Pause" : "Play") { player.togglePlay() }.keyboardShortcut(.space, modifiers: [])
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
                Button("Lyrics") { NotificationCenter.default.post(name: .openPlayer, object: nil); NotificationCenter.default.post(name: .playerPage, object: 0) }.keyboardShortcut("l", modifiers: .command)
            }
        }
        Settings {
            SettingsView().environmentObject(lib).environmentObject(updater)
        }
    }
}
