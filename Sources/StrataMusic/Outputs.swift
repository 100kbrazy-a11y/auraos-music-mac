import SwiftUI
import CoreAudio
import AudioToolbox
import AVFoundation

struct OutDevice: Identifiable, Hashable {
    var id: String { uid }
    let deviceID: AudioDeviceID
    let uid: String
    let name: String
}

/// the sound outputs of this Mac (speakers, headphones, USB and Bluetooth devices), and which one the app plays through
@MainActor
final class AudioOutputs: ObservableObject {
    static let shared = AudioOutputs()
    @Published private(set) var devices: [OutDevice] = []
    /// "" means whatever the Mac is set to use
    @Published var selected: String = UserDefaults.standard.string(forKey: "outputDevice") ?? "" {
        didSet { UserDefaults.standard.set(selected, forKey: "outputDevice"); Player.shared.applyOutputDevice() }
    }

    private init() {
        refresh()
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() { devices = Self.list() }

    var current: OutDevice? { devices.first { $0.uid == selected } }

    /// the device to use right now; nil = the Mac's default (also when the chosen one has been unplugged)
    var activeDevice: OutDevice? { selected.isEmpty ? nil : current }

    nonisolated private static func string(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let r = AudioObjectGetPropertyData(id, &a, 0, nil, &size, &cf)
        guard r == noErr, let c = cf else { return nil }
        return c.takeRetainedValue() as String
    }

    nonisolated private static func list() -> [OutDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        var out: [OutDevice] = []
        for id in ids {
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var sz: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &sz) == noErr, sz > 0 else { continue }
            let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(sz), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { raw.deallocate() }
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &sz, raw) == noErr else { continue }
            let bl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
            let channels = bl.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard channels > 0, let uid = string(id, kAudioDevicePropertyDeviceUID) else { continue }
            out.append(OutDevice(deviceID: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// a small speaker button in the player that lists the outputs
struct OutputButton: View {
    @ObservedObject private var out = AudioOutputs.shared

    var body: some View {
        Menu {
            Picker("Output", selection: $out.selected) {
                Text("System Default").tag("")
                ForEach(out.devices) { d in Text(d.name).tag(d.uid) }
            }.pickerStyle(.inline).labelsHidden()
        } label: {
            Image(systemName: "hifispeaker").foregroundStyle(out.activeDevice == nil ? Color.white.opacity(0.7) : Color.accentColor)
        }
        .menuStyle(.borderlessButton).hideMenuIndicator().fixedSize()
        .help(out.activeDevice.map { "Playing through \($0.name)" } ?? "Choose where the sound goes")
        .onAppear { out.refresh() }
    }
}
