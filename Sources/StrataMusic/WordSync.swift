import SwiftUI
import AppKit

/// downloads the model file, reporting progress
final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    var onProgress: (@Sendable (Double) -> Void)?
    var onDone: (@Sendable (Result<URL, Error>) -> Void)?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var finished = false

    func start(_ url: URL, expected: Int64) {
        self.expected = expected
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session = s
        task = s.downloadTask(with: url)
        task?.resume()
    }
    private var expected: Int64 = 0

    func cancel() { finished = true; task?.cancel(); session?.invalidateAndCancel() }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected
        if total > 0 { onProgress?(min(1, Double(totalBytesWritten) / Double(total))) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard !finished else { return }
        finished = true
        if let code = (downloadTask.response as? HTTPURLResponse)?.statusCode, code != 200 {
            onDone?(.failure(AlignError("The download failed (server answered \(code))")))
            return
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".onnx")
        do { try FileManager.default.moveItem(at: location, to: tmp); onDone?(.success(tmp)) }
        catch { onDone?(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, !finished else { return }
        finished = true
        onDone?(.failure(error))
    }
}

/// the model, the queue of one, and what the lyrics page and settings show about it
@MainActor
final class WordSync: ObservableObject {
    static let shared = WordSync()

    enum ModelState { case missing, downloading(Double), ready, failed(String) }

    @Published var model: ModelState = .missing
    @Published var busyID: String? = nil
    @Published var progress = 0.0
    @Published var lastError: String? = nil

    static let modelSize: Int64 = 356_000_000
    static let source = URL(string: "https://huggingface.co/Mes51/potlyrics-align/resolve/main/mms.onnx")!
    static var modelFile: URL {
        let d = Disk.dir.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("mms_fa_int8.onnx")
    }

    private var downloader: ModelDownloader?
    private var tried: Set<String> = []

    init() {
        let size = (try? FileManager.default.attributesOfItem(atPath: Self.modelFile.path)[.size] as? Int64) ?? 0
        if let size, size > 300_000_000 { model = .ready }
    }

    var ready: Bool { if case .ready = model { return true }; return false }

    // MARK: the model file

    func download() {
        switch model { case .downloading, .ready: return; default: break }
        model = .downloading(0)
        lastError = nil
        let d = ModelDownloader()
        d.onProgress = { [weak self] p in Task { @MainActor in
            guard let self else { return }
            if case .downloading = self.model { self.model = .downloading(p) }
        } }
        d.onDone = { [weak self] r in Task { @MainActor in self?.downloaded(r) } }
        downloader = d
        d.start(Self.source, expected: Self.modelSize)
    }

    func cancelDownload() {
        downloader?.cancel()
        downloader = nil
        model = .missing
    }

    private func downloaded(_ r: Result<URL, Error>) {
        downloader = nil
        guard case .downloading = model else { if case .success(let u) = r { try? FileManager.default.removeItem(at: u) }; return }
        switch r {
        case .failure(let e):
            model = .failed(e.localizedDescription)
        case .success(let tmp):
            let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int64) ?? 0
            guard let size, size > 300_000_000 else {
                try? FileManager.default.removeItem(at: tmp)
                model = .failed("The downloaded file is incomplete")
                return
            }
            try? FileManager.default.removeItem(at: Self.modelFile)
            do { try FileManager.default.moveItem(at: tmp, to: Self.modelFile); model = .ready }
            catch { model = .failed(error.localizedDescription) }
        }
    }

    func removeModel() {
        try? FileManager.default.removeItem(at: Self.modelFile)
        model = .missing
    }

    /// deletes every precise timing and shows the lyrics as they were
    func forgetAll() {
        let dir = Disk.dir.appendingPathComponent("lyrics", isDirectory: true)
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix(".aligned.lrc") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
        tried = []
        if let s = Player.shared.current { Task { await LyricsStore.shared.load(for: s) } }
    }

    // MARK: listening to a song

    /// called whenever a song's lyrics have loaded: starts the work if you asked for it to happen by itself
    func consider(_ s: Song) {
        guard UserDefaults.standard.bool(forKey: "preciseSync"), ready, busyID == nil, !tried.contains(s.id) else { return }
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        let store = LyricsStore.shared
        guard store.loadedID == s.id, store.synced, !store.wordSynced else { return }
        run(s)
    }

    func run(_ s: Song) {
        guard ready, busyID == nil else { return }
        let store = LyricsStore.shared
        guard store.loadedID == s.id, store.synced else { return }
        tried.insert(s.id)
        busyID = s.id
        progress = 0
        lastError = nil
        let lines = store.lines, offset = store.offset
        let url = s.url, path = Self.modelFile.path
        Task.detached(priority: .utility) { [weak self] in
            var text: String? = nil
            var failure: String? = nil
            do {
                text = try Aligner.align(url: url, modelPath: path, lines: lines, offset: offset) { p in
                    Task { @MainActor in self?.progress = p }
                }
            } catch { failure = error.localizedDescription }
            let result = text, problem = failure
            await MainActor.run { self?.finish(s, result, problem) }
        }
    }

    private func finish(_ s: Song, _ text: String?, _ problem: String?) {
        busyID = nil
        progress = 0
        if let problem { lastError = problem; return }
        guard let text else { lastError = "Couldn't find the words in \"\(s.title)\" (is it a song with singing?)"; return }
        let store = LyricsStore.shared
        try? text.write(to: store.alignedURL(s.id), atomically: true, encoding: .utf8)
        if store.loadedID == s.id, store.mergeAligned(id: s.id) { store.setOffset(0, song: s) }
    }
}

/// the part of Settings that sets it up
struct WordSyncSection: View {
    @ObservedObject private var sync = WordSync.shared
    @AppStorage("preciseSync") private var auto = false

    var body: some View {
        Section("Precise word timing") {
            Text("Listens to each song with Meta's MMS forced-alignment model (int8, run on your Mac with ONNX Runtime) so every word lights up when it is sung. One-time download of about 356 MB. It works on songs that already have timed lyrics, one song at a time in the background, and remembers the result.")
                .font(.callout).foregroundStyle(.secondary)
            switch sync.model {
            case .missing:
                HStack { Text("Model not downloaded"); Spacer(); Button("Download") { sync.download() } }
            case .downloading(let p):
                HStack { ProgressView(value: p).frame(maxWidth: .infinity); Text("\(Int(p * 100))%").monospacedDigit(); Button("Cancel") { sync.cancelDownload() } }
            case .ready:
                HStack { Label("Model ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green); Spacer(); Button("Remove model") { sync.removeModel() } }
            case .failed(let why):
                HStack { Text(why).foregroundStyle(.red).lineLimit(2); Spacer(); Button("Try again") { sync.removeModel(); sync.download() } }
            }
            Toggle("Sync words automatically when a song plays", isOn: $auto).disabled(!sync.ready)
            if sync.busyID != nil { HStack { ProgressView(value: sync.progress).frame(maxWidth: .infinity); Text("Listening…").foregroundStyle(.secondary) } }
            if let e = sync.lastError { Text(e).font(.callout).foregroundStyle(.red) }
            Button("Forget all precise timings") { sync.forgetAll() }
            Text("The MMS model is licensed CC BY-NC 4.0 (non-commercial use). It is downloaded from Hugging Face (Mes51/potlyrics-align) and never leaves your Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
