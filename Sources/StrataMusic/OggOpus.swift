import Foundation
import AVFoundation
import AudioToolbox

/// Ogg Opus files (the Android app's music packs, and .opus exports): the Mac can't open them, so the app reads their tags itself
/// and, the first time one is played, decodes it once into a plain audio file kept in its cache folder.
enum OggOpus {
    struct Info {
        var title = "", artist = "", album = "", albumArtist = "", year = "", track = 0
        var cover: Data?
        var duration = 0.0
        var channels = 2
        var preSkip = 312
    }
    struct Failure: LocalizedError { var errorDescription: String? }

    static let extensions: Set<String> = ["opus", "ogg", "oga"]
    static func isOpus(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    // MARK: reading the container

    /// every packet of the first logical stream, with the granule position of the page it ended on
    private static func packets(_ d: Data) -> [(data: Data, granule: Int64)] {
        var out: [(data: Data, granule: Int64)] = []
        var cur = Data()
        var i = d.startIndex
        let end = d.endIndex
        while i + 27 <= end {
            guard d[i] == 0x4F, d[i + 1] == 0x67, d[i + 2] == 0x67, d[i + 3] == 0x53 else { i += 1; continue }   // "OggS"
            var gran: Int64 = 0
            for k in 0..<8 { gran |= Int64(d[i + 6 + k]) << Int64(8 * k) }
            let nseg = Int(d[i + 26])
            guard i + 27 + nseg <= end else { break }
            var p = i + 27 + nseg
            for s in 0..<nseg {
                let len = Int(d[i + 27 + s])
                guard p + len <= end else { return out }
                cur.append(d[p..<(p + len)]); p += len
                if len < 255 { out.append((cur, gran)); cur = Data() }
            }
            i = p
        }
        return out
    }

    private static func le32(_ d: Data, _ o: Int) -> Int { Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8 | Int(d[d.startIndex + o + 2]) << 16 | Int(d[d.startIndex + o + 3]) << 24 }
    private static func be32(_ d: Data, _ o: Int) -> Int { Int(d[d.startIndex + o]) << 24 | Int(d[d.startIndex + o + 1]) << 16 | Int(d[d.startIndex + o + 2]) << 8 | Int(d[d.startIndex + o + 3]) }

    /// tags, cover, length: nil if this isn't Ogg Opus (for example Ogg Vorbis)
    static func parse(_ url: URL) -> Info? {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let pk = packets(d)
        guard pk.count >= 3, pk[0].data.count >= 19, String(data: pk[0].data.prefix(8), encoding: .ascii) == "OpusHead" else { return nil }
        var info = Info()
        info.channels = Int(pk[0].data[pk[0].data.startIndex + 9])
        info.preSkip = Int(pk[0].data[pk[0].data.startIndex + 10]) | Int(pk[0].data[pk[0].data.startIndex + 11]) << 8
        let last = pk.last?.granule ?? 0
        info.duration = max(0, Double(last - Int64(info.preSkip)) / 48000.0)
        let t = pk[1].data
        if t.count > 16, String(data: t.prefix(8), encoding: .ascii) == "OpusTags" {
            var o = 8
            let vlen = le32(t, o); o += 4 + vlen
            if o + 4 <= t.count {
                let n = le32(t, o); o += 4
                for _ in 0..<n {
                    guard o + 4 <= t.count else { break }
                    let l = le32(t, o); o += 4
                    guard l >= 0, o + l <= t.count else { break }
                    let s = String(decoding: t[(t.startIndex + o)..<(t.startIndex + o + l)], as: UTF8.self); o += l
                    guard let eq = s.firstIndex(of: "=") else { continue }
                    let key = s[s.startIndex..<eq].uppercased(), val = String(s[s.index(after: eq)...])
                    switch key {
                    case "TITLE": info.title = val
                    case "ARTIST": if info.artist.isEmpty { info.artist = val }
                    case "ALBUM": info.album = val
                    case "ALBUMARTIST": info.albumArtist = val
                    case "DATE", "YEAR": info.year = String(val.prefix(4))
                    case "TRACKNUMBER": info.track = Int(val.split(separator: "/").first ?? "") ?? 0
                    case "METADATA_BLOCK_PICTURE": if info.cover == nil { info.cover = picture(val) }
                    default: break
                    }
                }
            }
        }
        return info
    }

    /// a FLAC "picture" block, base64 encoded
    private static func picture(_ b64: String) -> Data? {
        guard let d = Data(base64Encoded: b64), d.count > 32 else { return nil }
        var o = 4
        let mime = be32(d, o); o += 4 + mime
        guard o + 4 <= d.count else { return nil }
        let desc = be32(d, o); o += 4 + desc + 16
        guard o + 4 <= d.count else { return nil }
        let len = be32(d, o); o += 4
        guard len > 0, o + len <= d.count else { return nil }
        return d[(d.startIndex + o)..<(d.startIndex + o + len)]
    }

    // MARK: decoding to a file the Mac can play

    /// how many 48 kHz samples one Opus packet holds (from its first byte)
    private static func frames(_ p: Data) -> Int {
        guard let toc = p.first else { return 0 }
        let cfg = Int(toc >> 3), c = Int(toc & 3)
        let size: Int
        switch cfg {
        case 0...11: size = [480, 960, 1920, 2880][cfg % 4]
        case 12...15: size = (cfg % 2 == 0) ? 480 : 960
        default: size = [120, 240, 480, 960][cfg % 4]
        }
        switch c {
        case 0: return size
        case 1, 2: return size * 2
        default: return p.count > 1 ? size * Int(p[p.startIndex + 1] & 0x3F) : 0
        }
    }

    static func decode(_ url: URL, to dest: URL) throws {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw Failure(errorDescription: "The file couldn't be read") }
        let pk = packets(d)
        guard pk.count > 3, String(data: pk[0].data.prefix(8), encoding: .ascii) == "OpusHead" else { throw Failure(errorDescription: "This isn't an Opus file") }
        let ch = max(1, min(2, Int(pk[0].data[pk[0].data.startIndex + 9])))
        let preSkip = Int(pk[0].data[pk[0].data.startIndex + 10]) | Int(pk[0].data[pk[0].data.startIndex + 11]) << 8

        var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 0,
                                               mBytesPerFrame: 0, mChannelsPerFrame: UInt32(ch), mBitsPerChannel: 0, mReserved: 0)
        guard let inFmt = AVAudioFormat(streamDescription: &asbd), let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: AVAudioChannelCount(ch), interleaved: false),
              let conv = AVAudioConverter(from: inFmt, to: outFmt) else { throw Failure(errorDescription: "This Mac can't decode Opus") }

        try? FileManager.default.removeItem(at: dest)
        let out = try AVAudioFile(forWriting: dest, settings: outFmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let audio = Array(pk.dropFirst(2))
        var idx = 0
        var skip = preSkip
        let chunk: AVAudioFrameCount = 960 * 6
        guard let pcm = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: chunk) else { throw Failure(errorDescription: "Not enough memory") }
        while idx < audio.count {
            pcm.frameLength = 0
            var err: NSError?
            let status = conv.convert(to: pcm, error: &err) { _, st in
                guard idx < audio.count else { st.pointee = .endOfStream; return nil }
                let p = audio[idx].data; idx += 1
                let buf = AVAudioCompressedBuffer(format: inFmt, packetCapacity: 1, maximumPacketSize: max(p.count, 1))
                p.withUnsafeBytes { raw in buf.data.copyMemory(from: raw.baseAddress!, byteCount: p.count) }
                buf.byteLength = UInt32(p.count); buf.packetCount = 1
                buf.packetDescriptions?[0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: UInt32(frames(p)), mDataByteSize: UInt32(p.count))
                st.pointee = .haveData
                return buf
            }
            if status == .error { throw err ?? Failure(errorDescription: "Decoding failed") }
            var n = Int(pcm.frameLength)
            if n == 0 { if status == .endOfStream { break } else { continue } }
            if skip > 0 {
                let drop = min(skip, n); skip -= drop; n -= drop
                if n == 0 { continue }
                for c in 0..<ch { let p = pcm.floatChannelData![c]; memmove(p, p + drop, n * MemoryLayout<Float>.size) }
                pcm.frameLength = AVAudioFrameCount(n)
            }
            try out.write(from: pcm)
        }
    }
}
