import Foundation
import UniformTypeIdentifiers

/// Settings for converting a whole folder (the in-app version of the `magick` loop).
public struct FolderJobConfig: Codable, Equatable, Sendable {
    public var inputPath: String
    public var outputPath: String
    public var settings: EncodeSettings
    public var recursive: Bool
    public var skipExisting: Bool

    public init(inputPath: String, outputPath: String, settings: EncodeSettings, recursive: Bool = true, skipExisting: Bool = true) {
        self.inputPath = inputPath
        self.outputPath = outputPath
        self.settings = settings
        self.recursive = recursive
        self.skipExisting = skipExisting
    }

    /// A sensible starting point: ~/Downloads/convert → ~/Downloads/avif, AVIF q45 at 50% size.
    public static let standard = FolderJobConfig(
        inputPath: "~/Downloads/convert",
        outputPath: "~/Downloads/avif",
        settings: EncodeSettings(format: .avif, quality: 45, resize: ResizeOptions(mode: .percent, percent: 50)))

    public var inputURL: URL { URL(fileURLWithPath: (inputPath as NSString).expandingTildeInPath).standardizedFileURL }
    public var outputURL: URL { URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath).standardizedFileURL }
}

public enum FolderScanner {
    private static let unsupportedExtensions: Set<String> = ["svg", "svgz", "pdf", "eps", "ai"]

    public static func isImage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty, !unsupportedExtensions.contains(ext), let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image)
    }

    /// Image files in `folder`. Skips hidden files and anything inside `excluding` (e.g. an output folder nested in the input).
    public static func imageFiles(in folder: URL, recursive: Bool, excluding: URL? = nil) -> [URL] {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], options: options)
        else { return [] }

        let root = folder.standardizedFileURL.path
        let excludedPath = excluding?.standardizedFileURL.path
        var files: [URL] = []
        for case let url as URL in enumerator {
            let path = url.standardizedFileURL.path
            if let excludedPath, excludedPath != root, path == excludedPath || path.hasPrefix(excludedPath + "/") {
                enumerator.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true, isImage(url) { files.append(url) }
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Expands dropped items: folders become their (recursive) image files.
    public static func expand(_ urls: [URL]) -> [URL] {
        urls.flatMap { url -> [URL] in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
            if isDirectory.boolValue { return imageFiles(in: url, recursive: true) }
            return isImage(url) ? [url] : []
        }
    }

    public static func outputURL(for input: URL, in folder: URL, format: OutputFormat) -> URL {
        folder.appendingPathComponent(input.deletingPathExtension().lastPathComponent)
            .appendingPathExtension(format.fileExtension)
    }

    /// Maps each input to its output path, mirroring subfolders of `inputRoot` under `outputRoot`.
    /// Inputs that would land on the same file (photo.jpg + photo.png → photo.avif) get their source
    /// extension added instead (photo-jpg.avif, photo-png.avif), so nothing is skipped or overwritten.
    public static func plannedOutputs(for files: [URL], inputRoot: URL, outputRoot: URL,
                                      format: OutputFormat) -> [URL: URL] {
        let rootPath = inputRoot.standardizedFileURL.path
        var planned: [URL: URL] = [:]
        var claims: [String: [URL]] = [:]
        for file in files {
            let directory = file.deletingLastPathComponent().standardizedFileURL.path
            let relative = directory.hasPrefix(rootPath)
                ? String(directory.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                : ""
            let folder = relative.isEmpty ? outputRoot : outputRoot.appendingPathComponent(relative, isDirectory: true)
            let destination = folder.appendingPathComponent(file.deletingPathExtension().lastPathComponent)
                .appendingPathExtension(format.fileExtension)
            planned[file] = destination
            // macOS volumes are usually case-insensitive.
            claims[destination.path.lowercased(), default: []].append(file)
        }
        for group in claims.values where group.count > 1 {
            for file in group {
                let name = "\(file.deletingPathExtension().lastPathComponent)-\(file.pathExtension.lowercased())"
                planned[file] = planned[file]!.deletingLastPathComponent()
                    .appendingPathComponent(name).appendingPathExtension(format.fileExtension)
            }
        }
        return planned
    }

    /// `name.ext`, or `name 2.ext`, `name 3.ext`… if taken. Never returns an existing file.
    public static func uniqueURL(in folder: URL, baseName: String, fileExtension: String) -> URL {
        var candidate = folder.appendingPathComponent(baseName).appendingPathExtension(fileExtension)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(baseName) \(counter)").appendingPathExtension(fileExtension)
            counter += 1
        }
        return candidate
    }
}
