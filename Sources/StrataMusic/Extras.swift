import SwiftUI
import AppKit
import AVKit

/// Up Next: the queue as a list you can jump around in
struct QueueView: View {
    @EnvironmentObject var player: Player
    @ObservedObject var radio = Radio.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Up Next").font(.system(size: 15, weight: .bold))
                if radio.active { Label(radio.loading ? "Radio…" : "Radio", systemImage: "dot.radiowaves.left.and.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(player.accent) }
                Spacer()
                if radio.active { Button("Stop Radio") { radio.stop() }.buttonStyle(.plain).foregroundStyle(.secondary) }
                if player.queue.count > player.index + 1 { Button("Clear") { player.clearUpNext() }.buttonStyle(.plain).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            if player.queue.isEmpty {
                Text("Nothing is queued").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(30)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(player.queue.enumerated()), id: \.offset) { i, s in
                                HStack(spacing: 10) {
                                    CoverView(song: s, size: 34, radius: 6)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(s.title).font(.system(size: 12.5, weight: i == player.index ? .bold : .regular)).lineLimit(1).foregroundStyle(i == player.index ? player.accent : Color.primary)
                                        HStack(spacing: 4) {
                                            if radio.ids.contains(s.id) && i > player.index { Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 9)).foregroundStyle(player.accent) }
                                            Text(s.shownArtist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    if i == player.index { Image(systemName: "speaker.wave.2.fill").font(.system(size: 11)).foregroundStyle(player.accent) }
                                    else { Button { player.removeFromQueue(i) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }.buttonStyle(.plain).foregroundStyle(.secondary).help("Remove from the queue") }
                                }
                                .padding(.horizontal, 14).padding(.vertical, 5)
                                .background(i == player.index ? Color.white.opacity(0.07) : Color.clear)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { player.jump(to: i) }
                                .contextMenu {
                                    Button("Play") { player.jump(to: i) }
                                    if i != player.index { Button("Remove from Up Next") { player.removeFromQueue(i) } }
                                    Button("Go to Artist") { NotificationCenter.default.post(name: .goRef, object: ArtistRef(name: s.artistKey)) }
                                }
                                .id(i)
                            }
                        }
                    }
                    .onAppear { proxy.scrollTo(player.index, anchor: .top) }
                }
            }
        }
        .frame(width: 340, height: 420)
    }
}

enum QueueScope { case bar, player, none }

struct QueueButton: View {
    var scope: QueueScope = .bar
    @State private var show = false
    var body: some View {
        Button { show.toggle() } label: { Image(systemName: "list.bullet") }
            .buttonStyle(.plain).help("Up Next (⌘U)")
            // ⌘U: only the button that's actually on screen answers (the bar's, or the full player's)
            .onReceive(NotificationCenter.default.publisher(for: .toggleQueue)) { _ in
                if scope != .none && (scope == .player) == Presence.playerOpen { show.toggle() }
            }
            .popover(isPresented: $show, arrowEdge: .top) { QueueView() }
    }
}

struct SleepButton: View {
    @EnvironmentObject var player: Player
    var body: some View {
        Menu {
            if player.sleepEnd != nil || player.sleepAtSongEnd {
                Button("Turn Sleep Timer Off") { player.cancelSleep() }
                Divider()
            }
            ForEach([15, 30, 45, 60, 90], id: \.self) { m in Button("In \(m) minutes") { player.sleep(minutes: m) } }
            Button("After this song") { player.sleepAfterThisSong() }
        } label: {
            Image(systemName: player.sleepEnd != nil || player.sleepAtSongEnd ? "moon.zzz.fill" : "moon.zzz")
        }
        .menuStyle(.borderlessButton).hideMenuIndicator().fixedSize()
        .help(player.sleepAtSongEnd ? "Stops after this song" : (player.sleepEnd.map { "Stops at " + $0.formatted(date: .omitted, time: .shortened) } ?? "Sleep timer"))
    }
}

/// opens the Settings window (⌘,)
func openSettingsWindow() {
    if #available(macOS 14, *) { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
    else { NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil) }
}

/// lets a view reach its NSWindow (to hide the title while the full-screen player is up)
struct WindowAccessor: NSViewRepresentable {
    var configure: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) { DispatchQueue.main.async { if let w = v.window { configure(w) } } }
}

/// the AirPlay / output picker
struct RoutePicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView(); v.isRoutePickerButtonBordered = false; return v
    }
    func updateNSView(_ v: AVRoutePickerView, context: Context) {}
}

/// playback speed: a button that opens a slider (0.5x to 2x, snapping to steps of 0.05, so 1.10x is one of them) with the usual speeds under it
struct SpeedButton: View {
    @EnvironmentObject var player: Player
    @State private var show = false

    var body: some View {
        Button { show.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "speedometer")
                if player.speed != 1 { Text(String(format: "%.2f×", player.speed)).font(.system(size: 11, weight: .semibold)).monospacedDigit() }
            }
        }
        .buttonStyle(.plain).help(String(format: "Speed: %.2f×", player.speed))
        .popover(isPresented: $show, arrowEdge: .top) { SpeedPopover().environmentObject(player) }
    }
}

struct SpeedPopover: View {
    @EnvironmentObject var player: Player
    private let presets: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Speed").font(.headline)
                Spacer()
                Text(String(format: "%.2f×", player.speed)).font(.system(size: 15, weight: .semibold)).monospacedDigit()
            }
            Slider(value: Binding(get: { Double(player.speed) }, set: { player.speed = Float(($0 * 20).rounded() / 20) }), in: 0.5...2, step: 0.05)
            HStack(spacing: 6) {
                ForEach(presets, id: \.self) { r in
                    Button(r == 1 ? "1×" : "\(r.formatted())×") { player.speed = r }.buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .padding(16).frame(width: 300)
    }
}
