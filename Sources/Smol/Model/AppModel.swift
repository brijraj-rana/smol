import AppKit
import Observation
import SmolCore
import UniformTypeIdentifiers

enum Screen {
    case home, editor, watch
}

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()
    /// Set by the DEBUG snapshot hook so a stray pointer doesn't end up in screenshots.
    static var ignoresPointer = false

    var screen: Screen = .home
    var items: [ImageItem] = []
    var selection: ImageItem.ID? {
        didSet { if selection != oldValue { selectionDidChange(from: oldValue) } }
    }
    var settings: EncodeSettings {
        didSet {
            guard settings != oldValue else { return }
            Self.save(settings, key: Self.settingsKey)
            scheduleEncode()
        }
    }
    var preferences: Preferences {
        didSet {
            guard preferences != oldValue else { return }
            Self.save(preferences, key: Self.preferencesKey)
            if preferences.appearance != oldValue.appearance { NSApp.appearance = preferences.appearance.nsAppearance }
        }
    }
    var isExporting = false
    var toast: String?

    let watcher = FolderWatcher()

    @ObservationIgnored private var encodeTask: Task<Void, Never>?
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    private static let settingsKey = "encodeSettings"
    private static let preferencesKey = "preferences"

    init() {
        settings = Self.load(EncodeSettings.self, key: Self.settingsKey) ?? EncodeSettings()
        preferences = Self.load(Preferences.self, key: Self.preferencesKey) ?? Preferences()
    }

    var selectedItem: ImageItem? { items.first { $0.id == selection } }

    // MARK: - Adding & removing

    func presentOpenPanel(format: OutputFormat? = nil, resize: ResizeOptions? = nil) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.image]
        panel.message = "Choose images or folders to compress"
        guard panel.runModal() == .OK else { return }
        add(urls: panel.urls, format: format, resize: resize)
    }

    func add(urls: [URL], format: OutputFormat? = nil, resize: ResizeOptions? = nil) {
        if let format { settings.format = format }
        if let resize { settings.resize = resize }
        Task { await addResolving(urls) }
    }

    /// Folder expansion and file stats happen off the main thread, so huge drops don't beachball.
    private func addResolving(_ urls: [URL]) async {
        let found = await Self.expandOffMain(urls)
        let existing = Set(items.map { $0.url.standardizedFileURL })
        var seen = existing
        let newItems = found.compactMap { url, size -> ImageItem? in
            guard seen.insert(url).inserted else { return nil }
            return ImageItem(url: url, fileSize: size)
        }

        if newItems.isEmpty {
            if !urls.isEmpty { showToast(existing.isEmpty ? "No images found in what you dropped" : "Those images are already added") }
            if !items.isEmpty { screen = .editor }
            return
        }

        items.append(contentsOf: newItems)
        for item in newItems { loadMetadata(item) }
        screen = .editor
        selection = newItems.first?.id
        scheduleEncode(debounce: false)
    }

    func remove(_ ids: Set<ImageItem.ID>) {
        let wasSelected = selection.map(ids.contains) ?? false
        let index = items.firstIndex { $0.id == selection } ?? 0
        items.removeAll { ids.contains($0.id) }
        if wasSelected {
            selection = items.isEmpty ? nil : items[min(index, items.count - 1)].id
        }
        if items.isEmpty { screen = .home }
    }

    func removeAll() {
        encodeTask?.cancel()
        items.removeAll()
        selection = nil
        screen = .home
    }

    nonisolated private static func expandOffMain(_ urls: [URL]) async -> [(URL, Int64)] {
        FolderScanner.expand(urls).map { url in
            let standardized = url.standardizedFileURL
            let size = (try? standardized.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return (standardized, Int64(size))
        }
    }

    private func loadMetadata(_ item: ImageItem) {
        let url = item.url
        Task {
            let (thumbnail, info) = await Self.readMetadata(url)
            item.thumbnail = thumbnail
            item.info = info
            if info == nil { item.loadError = "Can't read this image" }
        }
    }

    nonisolated private static func readMetadata(_ url: URL) async -> (CGImage?, ImageInfo?) {
        (ImageDecoder.thumbnail(url: url, maxPixelSize: 96), ImageDecoder.info(url: url))
    }

    // MARK: - Encoding

    /// Re-encodes every item that's out of date, selected item first, a few at a time.
    func scheduleEncode(debounce: Bool = true) {
        encodeTask?.cancel()
        encodeTask = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled, let self else { return }
            await self.encodeOutdated()
        }
    }

    private func encodeOutdated() async {
        let settings = self.settings
        var queue = items.filter { !$0.isCurrent(settings) && $0.loadError == nil }
        if let index = queue.firstIndex(where: { $0.id == selection }) {
            queue.insert(queue.remove(at: index), at: 0)
        }
        let limit = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
        await withTaskGroup(of: Void.self) { group in
            var pending = queue.makeIterator()
            for _ in 0..<limit {
                guard let item = pending.next() else { break }
                group.addTask { await self.encode(item, settings: settings) }
            }
            while await group.next() != nil {
                if Task.isCancelled { group.cancelAll(); break }
                if let item = pending.next() {
                    group.addTask { await self.encode(item, settings: settings) }
                }
            }
        }
    }

    func encode(_ item: ImageItem, settings: EncodeSettings) async {
        guard item.loadError == nil else { return }
        item.encodingCount += 1
        defer { item.encodingCount -= 1 }
        let wantsPreview = item.id == selection
        do {
            let (encoded, preview) = try await Self.encodeOffMain(
                url: item.url, original: item.original, settings: settings, wantsPreview: wantsPreview)
            // Never let a stale result replace one that matches the current settings.
            guard settings == self.settings || !item.isCurrent(self.settings) else { return }
            item.result = encoded
            item.resultSettings = settings
            item.error = nil
            if item.id == selection {
                // The item may have been selected after this encode started (so no preview was made).
                let decoded = if let preview { preview } else { await Self.decodeOffMain(data: encoded.data) }
                if item.id == selection && item.result?.data == encoded.data { item.preview = decoded }
            }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            guard settings == self.settings || !item.isCurrent(self.settings) else { return }
            item.result = nil
            item.resultSettings = settings
            item.error = error.localizedDescription
            if item.id == selection { item.preview = nil }
        }
    }

    nonisolated private static func encodeOffMain(url: URL, original: CGImage?, settings: EncodeSettings,
                                                  wantsPreview: Bool) async throws -> (EncodedImage, CGImage?) {
        let image = try original ?? ImageDecoder.decode(url: url)
        let encoded = try await ImageEncoder.encode(image, settings: settings)
        let preview = wantsPreview ? try? ImageDecoder.decode(data: encoded.data) : nil
        return (encoded, preview)
    }

    nonisolated private static func decodeOffMain(url: URL) async -> CGImage? { try? ImageDecoder.decode(url: url) }
    nonisolated private static func decodeOffMain(data: Data) async -> CGImage? { try? ImageDecoder.decode(data: data) }

    private func selectionDidChange(from oldID: ImageItem.ID?) {
        if let oldID, let old = items.first(where: { $0.id == oldID }) { old.releaseHeavyData() }
        selectionTask?.cancel()
        guard let item = selectedItem else { return }
        selectionTask = Task {
            let original = await Self.decodeOffMain(url: item.url)
            guard !Task.isCancelled, self.selection == item.id else { return }
            item.original = original
            if let result = item.currentResult(settings) {
                let preview = await Self.decodeOffMain(data: result.data)
                if self.selection == item.id { item.preview = preview }
            } else if !item.isEncoding && !item.isCurrent(settings) {
                await encode(item, settings: settings)
            }
        }
    }

    // MARK: - Totals

    /// `processed` counts finished items, including failures; sizes only count successes.
    var totals: (processed: Int, input: Int64, output: Int64) {
        var processed = 0, input: Int64 = 0, output: Int64 = 0
        for item in items {
            if item.loadError != nil || item.isCurrent(settings) { processed += 1 }
            guard let result = item.currentResult(settings) else { continue }
            input += item.fileSize
            output += result.byteCount
        }
        return (processed, input, output)
    }

    // MARK: - Tools

    /// Bumped when Homebrew tools appear or disappear, so views re-check availability.
    var toolsRevision = 0

    /// Called when the app becomes active, e.g. after running `brew install webp` in Terminal.
    func refreshTools() {
        guard ExternalTool.refresh() else { return }
        toolsRevision += 1
        for item in items where item.error != nil { item.resultSettings = nil }
        scheduleEncode(debounce: false)
    }

    // MARK: - Export

    /// The Save button and ⌘S: goes wherever Settings says.
    func saveAll() {
        guard !items.isEmpty else { return }
        switch preferences.destination {
        case .ask:
            exportToChosenFolder()
        case .besideOriginal:
            exportNextToOriginals()
        case .folder:
            guard let folder = preferences.folderURL else { return chooseOutputFolder(thenSave: true) }
            Task { await export(to: folder) }
        }
    }

    /// Picks the folder all future saves go to.
    func chooseOutputFolder(thenSave: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose where Smol saves compressed images"
        panel.directoryURL = preferences.folderURL
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        preferences.folderPath = folder.path
        preferences.destination = .folder
        if thenSave { Task { await export(to: folder) } }
    }

    func exportToChosenFolder() {
        guard !items.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose where to save \(items.count) compressed image\(items.count == 1 ? "" : "s")"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { await export(to: folder) }
    }

    func exportNextToOriginals() {
        guard !items.isEmpty else { return }
        Task { await export(to: nil) }
    }

    /// Writes every item. `folder == nil` saves beside each original. Never overwrites anything.
    func export(to folder: URL?) async {
        guard !isExporting else { return }
        isExporting = true
        defer { isExporting = false }
        encodeTask?.cancel()
        await encodeOutdated()

        let settings = self.settings
        var saved: [URL] = []
        var failed = 0
        var bytesIn: Int64 = 0, bytesOut: Int64 = 0
        for item in items where item.loadError == nil {
            guard let result = item.currentResult(settings) else { failed += 1; continue }
            // Pasted images live in a temp folder; "next to originals" means Downloads for those.
            var directory = folder ?? item.url.deletingLastPathComponent()
            if folder == nil, directory.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
                directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? directory
            }
            let destination = FolderScanner.uniqueURL(in: directory, baseName: item.baseName + preferences.cleanSuffix,
                                                      fileExtension: settings.format.fileExtension)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try result.data.write(to: destination, options: .withoutOverwriting)
                saved.append(destination)
                bytesIn += item.fileSize
                bytesOut += result.byteCount
            } catch {
                failed += 1
            }
        }

        var message = "Saved \(saved.count) image\(saved.count == 1 ? "" : "s")"
        if bytesIn > 0 { message += " · \(Format.bytes(bytesIn)) → \(Format.bytes(bytesOut))" }
        if failed > 0 { message += " · \(failed) failed" }
        showToast(message)
        if !saved.isEmpty && preferences.revealAfterSave { NSWorkspace.shared.activateFileViewerSelecting(saved) }
    }

    /// A temp copy of the compressed file, so rows can be dragged straight into Finder, Slack, etc.
    func dragProvider(for item: ImageItem) -> NSItemProvider {
        guard let file = temporaryOutputFile(for: item) else {
            return NSItemProvider(object: item.url as NSURL)
        }
        return NSItemProvider(contentsOf: file) ?? NSItemProvider(object: file as NSURL)
    }

    private func temporaryOutputFile(for item: ImageItem) -> URL? {
        guard let result = item.currentResult(settings) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("smol-out-\(item.id.uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(item.baseName).appendingPathExtension(settings.format.fileExtension)
        do {
            try result.data.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }

    // MARK: - Clipboard

    /// Adds files copied in Finder, or raw image data (e.g. a screenshot copied with ⌃⇧⌘4).
    func pasteFromClipboard() {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            add(urls: urls)
            return
        }
        guard let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:])
        else {
            showToast("No image on the clipboard")
            return
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("smol-paste")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Date().formatted(.dateTime.hour().minute().second()).replacingOccurrences(of: ":", with: ".")
        let file = FolderScanner.uniqueURL(in: dir, baseName: "Pasted \(stamp)", fileExtension: "png")
        do {
            try png.write(to: file)
            add(urls: [file])
        } catch {
            showToast("Couldn't read the clipboard image")
        }
    }

    /// Puts the compressed file on the clipboard, ready to paste into Finder, Slack, Figma, a browser…
    func copyCompressed(_ item: ImageItem? = nil) {
        guard let item = item ?? selectedItem, let file = temporaryOutputFile(for: item),
              let result = item.currentResult(settings) else {
            showToast("Nothing to copy yet")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        showToast("Copied \(file.lastPathComponent) · \(Format.bytes(result.byteCount))")
    }

    // MARK: - Toast

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self.toast = nil
        }
    }

    // MARK: - Persistence

    static func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

enum Format {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func savings(_ fraction: Double) -> String {
        let percent = Int((fraction * 100).rounded())
        return percent >= 0 ? "−\(percent)%" : "+\(-percent)%"
    }
}
