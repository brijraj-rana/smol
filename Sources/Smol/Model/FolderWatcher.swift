import AppKit
import Observation
import SmolCore

/// Converts every image in an input folder into an output folder, once or continuously.
/// The in-app version of a `find … | magick … .avif` shell loop.
@MainActor @Observable
final class FolderWatcher {
    struct LogEntry: Identifiable {
        let id = UUID()
        let date = Date()
        let name: String
        let inputBytes: Int64
        let outputBytes: Int64?
        let message: String?

        var isError: Bool { outputBytes == nil }
    }

    struct Candidate: Sendable {
        let url: URL
        let destination: URL
        let size: Int64
        let modified: Date
    }

    var config: FolderJobConfig {
        didSet { if config != oldValue { AppModel.save(config, key: Self.configKey) } }
    }
    private(set) var isWatching = false
    private(set) var isBusy = false
    private(set) var log: [LogEntry] = []
    private(set) var convertedCount = 0
    private(set) var failedCount = 0
    private(set) var bytesIn: Int64 = 0
    private(set) var bytesOut: Int64 = 0
    private(set) var lastScan: Date?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var seenSizes: [URL: Int64] = [:]
    @ObservationIgnored private var failedStamps: [URL: Date] = [:]
    private static let configKey = "folderJobConfig"

    init() {
        config = AppModel.load(FolderJobConfig.self, key: Self.configKey) ?? .standard
    }

    // MARK: - Folder pickers

    func chooseInputFolder() {
        if let url = pickFolder(message: "Choose the folder to convert images from") { config.inputPath = url.path }
    }

    func chooseOutputFolder() {
        if let url = pickFolder(message: "Choose where converted images go") { config.outputPath = url.path }
    }

    private func pickFolder(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }

    func reveal(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    // MARK: - Running

    func convertNow() {
        guard !isBusy else { return }
        Task { await runPass(watching: false) }
    }

    func toggleWatching() {
        isWatching ? stopWatching() : startWatching()
    }

    func startWatching() {
        guard !isWatching else { return }
        try? FileManager.default.createDirectory(at: config.inputURL, withIntermediateDirectories: true)
        isWatching = true
        seenSizes = [:]
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isWatching, !self.isBusy else { return }
                await self.runPass(watching: true)
            }
        }
        Task { await runPass(watching: true) }
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
        isWatching = false
    }

    func clearLog() {
        log.removeAll()
        convertedCount = 0
        failedCount = 0
        bytesIn = 0
        bytesOut = 0
        failedStamps = [:]
    }

    /// One scan + convert pass. When watching, a file is only converted once its size has been stable
    /// for one tick (so half-copied files are skipped) and already-converted files are always skipped.
    private func runPass(watching: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        let config = self.config
        let skipExisting = config.skipExisting || watching
        let candidates = await Self.scan(config: config, skipExisting: skipExisting)
        lastScan = Date()

        var ready: [Candidate] = []
        var nextSeen: [URL: Int64] = [:]
        for candidate in candidates {
            if failedStamps[candidate.url] == candidate.modified { continue }
            if watching && seenSizes[candidate.url] != candidate.size {
                nextSeen[candidate.url] = candidate.size
                continue
            }
            ready.append(candidate)
        }
        if watching { seenSizes = nextSeen }

        guard !ready.isEmpty else {
            if !watching {
                let total = FolderScanner.imageFiles(in: config.inputURL, recursive: config.recursive).count
                log.insert(LogEntry(name: total == 0 ? "No images in \(config.inputURL.lastPathComponent)"
                                                     : "All \(total) images are already converted",
                                    inputBytes: 0, outputBytes: 0, message: "info"), at: 0)
            }
            return
        }

        do {
            try FileManager.default.createDirectory(at: config.outputURL, withIntermediateDirectories: true)
        } catch {
            log.insert(LogEntry(name: config.outputURL.path, inputBytes: 0, outputBytes: nil,
                                message: "Can't create output folder: \(error.localizedDescription)"), at: 0)
            return
        }

        let settings = config.settings
        let limit = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
        await withTaskGroup(of: (Candidate, Result<Int64, Error>).self) { group in
            var pending = ready.makeIterator()
            for _ in 0..<limit {
                guard let next = pending.next() else { break }
                group.addTask { await Self.convert(next, settings: settings) }
            }
            while let (candidate, result) = await group.next() {
                record(candidate, result)
                if let next = pending.next() {
                    group.addTask { await Self.convert(next, settings: settings) }
                }
            }
        }
    }

    private func record(_ candidate: Candidate, _ result: Result<Int64, Error>) {
        switch result {
        case .success(let outputBytes):
            convertedCount += 1
            bytesIn += candidate.size
            bytesOut += outputBytes
            failedStamps[candidate.url] = nil
            log.insert(LogEntry(name: candidate.url.lastPathComponent, inputBytes: candidate.size,
                                outputBytes: outputBytes, message: nil), at: 0)
        case .failure(let error):
            failedCount += 1
            failedStamps[candidate.url] = candidate.modified
            log.insert(LogEntry(name: candidate.url.lastPathComponent, inputBytes: candidate.size,
                                outputBytes: nil, message: error.localizedDescription), at: 0)
        }
        if log.count > 500 { log.removeLast(log.count - 500) }
    }

    nonisolated private static func scan(config: FolderJobConfig, skipExisting: Bool) async -> [Candidate] {
        let output = config.outputURL
        let files = FolderScanner.imageFiles(in: config.inputURL, recursive: config.recursive, excluding: output)
        let plan = FolderScanner.plannedOutputs(for: files, inputRoot: config.inputURL, outputRoot: output,
                                                format: config.settings.format)
        return files.compactMap { url in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = Int64(values?.fileSize ?? 0)
                let modified = values?.contentModificationDate ?? .distantPast
                guard size > 0, let destination = plan[url] else { return nil }
                if destination.standardizedFileURL == url.standardizedFileURL { return nil }
                if skipExisting,
                   let outputDate = try? destination.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   outputDate >= modified {
                    return nil
                }
                return Candidate(url: url, destination: destination, size: size, modified: modified)
            }
    }

    nonisolated private static func convert(_ candidate: Candidate,
                                            settings: EncodeSettings) async -> (Candidate, Result<Int64, Error>) {
        do {
            let encoded = try await ImageEncoder.encode(url: candidate.url, settings: settings)
            try FileManager.default.createDirectory(at: candidate.destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try encoded.data.write(to: candidate.destination, options: .atomic)
            return (candidate, .success(encoded.byteCount))
        } catch {
            return (candidate, .failure(error))
        }
    }
}
