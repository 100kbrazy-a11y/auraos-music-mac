import Foundation
import AVFoundation
import AudioToolbox
import SwiftUI
import AppKit

enum ExportFormat: String, CaseIterable, Identifiable {
    case original = "Original", m4a = "M4A (AAC)", alac = "ALAC (lossless M4A)", flac = "FLAC", wav = "WAV", aiff = "AIFF"
    var id: String { rawValue }
    var ext: String {
        switch self { case .original: return ""; case .m4a, .alac: return "m4a"; case .flac: return "flac"; case .wav: return "wav"; case .aiff: return "aiff" }
    }
    var note: String {
        switch self {
        case .original: return "The file exactly as it is in your library. Nothing is converted."
        case .m4a: return "Re-encoded to AAC (256 kbps): small files that play everywhere."
        case .alac: return "Lossless, Apple's format: smaller than WAV, plays in Music and on iPhone."
        case .flac: return "Lossless, plays almost everywhere. A song that is already lossy won't sound better, only bigger."
        case .wav: return "Uncompressed. Large files, readable by anything."
        case .aiff: return "Uncompressed, the Mac's own format."
        }
    }
}

enum Exporter {
    struct Failure: LocalizedError { var errorDescription: String? }

    static func export(_ s: Song, as f: ExportFormat, to dest: URL, progress: @escaping (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: dest)
        switch f {
        case .original:
            try FileManager.default.copyItem(at: s.url, to: dest)
        case .m4a:
            let asset = AVURLAsset(url: s.url)
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw Failure(errorDescription: "This song can't be exported as M4A") }
            session.outputURL = dest; session.outputFileType = .m4a
            await session.export()
            if session.status != .completed { throw Failure(errorDescription: session.error?.localizedDescription ?? "The export didn't finish") }
        case .alac, .flac, .wav, .aiff:
            try await Task.detached { try convert(s, f, dest, progress) }.value
        }
    }

    private static func convert(_ s: Song, _ f: ExportFormat, _ dest: URL, _ progress: (Double) -> Void) throws {
        let inFile = try AVAudioFile(forReading: s.url)
        let fmt = inFile.processingFormat
        var settings: [String: Any] = [AVSampleRateKey: fmt.sampleRate, AVNumberOfChannelsKey: Int(fmt.channelCount)]
        switch f {
        case .alac: settings[AVFormatIDKey] = kAudioFormatAppleLossless; settings[AVEncoderBitDepthHintKey] = 16
        case .flac: settings[AVFormatIDKey] = kAudioFormatFLAC; settings[AVEncoderBitDepthHintKey] = 16
        case .wav, .aiff:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsNonInterleaved] = false
            settings[AVLinearPCMIsBigEndianKey] = (f == .aiff)
        default: break
        }
        let out = try AVAudioFile(forWriting: dest, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 32768) else { throw Failure(errorDescription: "Not enough memory") }
        while inFile.framePosition < inFile.length {
            try inFile.read(into: buf)
            if buf.frameLength == 0 { break }
            try out.write(from: buf)
            progress(Double(inFile.framePosition) / Double(max(1, inFile.length)))
        }
    }
}

struct ExportSheet: View {
    let song: Song
    @Environment(\.dismiss) private var dismiss
    @State private var format: ExportFormat = .original
    @State private var working = false
    @State private var progress = 0.0
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export").font(.title2.weight(.bold))
            Text("\(song.title) · \(song.shownArtist)").foregroundStyle(.secondary).lineLimit(1)
            Picker("Format", selection: $format) { ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) } }
            Text(format.note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if working { ProgressView(value: progress).progressViewStyle(.linear) }
            if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") { go() }.keyboardShortcut(.defaultAction).disabled(working)
            }
        }
        .padding(24).frame(width: 440)
    }

    private func go() {
        let p = NSSavePanel()
        let ext = format == .original ? song.ext : format.ext
        p.nameFieldStringValue = "\(song.shownArtist) - \(song.title).\(ext)"
        p.canCreateDirectories = true
        guard p.runModal() == .OK, let dest = p.url else { return }
        working = true; message = ""; progress = 0
        Task {
            do {
                try await Exporter.export(song, as: format, to: dest) { v in Task { @MainActor in progress = v } }
                NSWorkspace.shared.activateFileViewerSelecting([dest])
                dismiss()
            } catch { message = error.localizedDescription }
            working = false
        }
    }
}
