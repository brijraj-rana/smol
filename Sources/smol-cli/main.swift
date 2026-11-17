import Foundation
import SmolCore

// smol-cli: the same engine as the app, for scripts and shell loops.

let usage = """
smol — convert and compress images

USAGE
  smol <files or folders…> [options]

OPTIONS
  -f, --format <name>     avif, webp, jxl, heic, jpeg, png, tiff, gif, bmp   (default: webp)
  -q, --quality <1-100>   lossy quality                                      (default: 75)
      --max-size <size>   pick the quality automatically to fit, e.g. 200kb or 1.5mb
      --lossless          lossless WebP / JPEG XL
      --resize <spec>     50%  or  1920x1080 (fit within, keeps aspect ratio)
      --effort <level>    fast, balanced, best                               (default: balanced)
  -o, --output <folder>   write here instead of next to each original
      --overwrite         replace existing files instead of writing "name 2.ext"
  -h, --help

EXAMPLES
  smol photo.jpg -f avif -q 45
  smol ~/Downloads/convert -f avif -q 45 --resize 50% -o ~/Downloads/avif
  smol hero.png -f webp --max-size 200kb
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("smol: \(message)\n".utf8))
    exit(2)
}

func parseSize(_ text: String) -> Int? {
    let lower = text.lowercased()
    let (digits, multiplier): (Substring, Double) =
        lower.hasSuffix("mb") ? (lower.dropLast(2), 1000) :
        lower.hasSuffix("kb") ? (lower.dropLast(2), 1) :
        lower.hasSuffix("k") ? (lower.dropLast(1), 1) : (Substring(lower), 1)
    guard let value = Double(digits), value > 0 else { return nil }
    return max(1, Int(value * multiplier))
}

var settings = EncodeSettings()
var inputs: [URL] = []
var outputFolder: URL?
var overwrite = false

var arguments = Array(CommandLine.arguments.dropFirst())
func nextValue(for flag: String) -> String {
    guard !arguments.isEmpty else { fail("\(flag) needs a value") }
    return arguments.removeFirst()
}

while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "-h", "--help":
        print(usage)
        exit(0)
    case "-f", "--format":
        let name = nextValue(for: argument).lowercased()
        let aliases = ["jpg": "jpeg", "jpegxl": "jxl", "tif": "tiff", "heif": "heic"]
        guard let format = OutputFormat(rawValue: aliases[name] ?? name) else { fail("unknown format '\(name)'") }
        settings.format = format
    case "-q", "--quality":
        guard let quality = Double(nextValue(for: argument)), (1...100).contains(quality) else { fail("quality must be 1-100") }
        settings.quality = quality
    case "--max-size":
        guard let kilobytes = parseSize(nextValue(for: argument)) else { fail("--max-size expects something like 200kb or 1.5mb") }
        settings.targetKB = kilobytes
    case "--lossless":
        settings.lossless = true
    case "--effort":
        guard let effort = Effort(rawValue: nextValue(for: argument).lowercased()) else { fail("effort must be fast, balanced or best") }
        settings.effort = effort
    case "--resize":
        let spec = nextValue(for: argument).lowercased()
        if spec.hasSuffix("%"), let percent = Double(spec.dropLast()), percent > 0 {
            settings.resize = ResizeOptions(mode: .percent, percent: percent)
        } else {
            let parts = spec.split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { fail("--resize expects 50% or 1920x1080") }
            settings.resize = ResizeOptions(mode: .fit, maxWidth: parts[0], maxHeight: parts[1])
        }
    case "-o", "--output":
        outputFolder = URL(fileURLWithPath: (nextValue(for: argument) as NSString).expandingTildeInPath)
    case "--overwrite":
        overwrite = true
    default:
        if argument.hasPrefix("-") { fail("unknown option '\(argument)' (try --help)") }
        inputs.append(URL(fileURLWithPath: (argument as NSString).expandingTildeInPath))
    }
}

guard !inputs.isEmpty else {
    print(usage)
    exit(2)
}
guard settings.format.isAvailable else {
    fail("\(settings.format.displayName) needs: \(settings.format.requiredTool?.installCommand ?? "a newer macOS")")
}

let files = FolderScanner.expand(inputs)
guard !files.isEmpty else { fail("no images found") }
if let outputFolder {
    do { try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true) }
    catch { fail("can't create \(outputFolder.path): \(error.localizedDescription)") }
}

func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }

struct Outcome: Sendable {
    let name: String
    let input: Int64
    let output: Int64?
    let message: String
}

func convert(_ file: URL, settings: EncodeSettings, outputFolder: URL?, overwrite: Bool) async -> Outcome {
    let inputSize = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    do {
        let encoded = try await ImageEncoder.encode(url: file, settings: settings)
        let folder = outputFolder ?? file.deletingLastPathComponent()
        let base = file.deletingPathExtension().lastPathComponent
        var destination = folder.appendingPathComponent(base).appendingPathExtension(settings.format.fileExtension)
        // Never clobber the source, and never clobber anything else unless asked.
        if !overwrite || destination.standardizedFileURL == file.standardizedFileURL {
            destination = FolderScanner.uniqueURL(in: folder, baseName: base, fileExtension: settings.format.fileExtension)
        }
        try encoded.data.write(to: destination, options: .atomic)
        let saved = inputSize > 0 ? Int((1 - Double(encoded.byteCount) / Double(inputSize)) * 100) : 0
        return Outcome(name: file.lastPathComponent, input: inputSize, output: encoded.byteCount,
                       message: "\(bytes(inputSize)) → \(bytes(encoded.byteCount))  \(saved >= 0 ? "−" : "+")\(abs(saved))%  \(destination.lastPathComponent)")
    } catch {
        return Outcome(name: file.lastPathComponent, input: inputSize, output: nil, message: error.localizedDescription)
    }
}

var totalIn: Int64 = 0, totalOut: Int64 = 0, failures = 0
let limit = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
let jobSettings = settings, jobFolder = outputFolder, jobOverwrite = overwrite

await withTaskGroup(of: Outcome.self) { group in
    var pending = files.makeIterator()
    for _ in 0..<limit {
        guard let file = pending.next() else { break }
        group.addTask { await convert(file, settings: jobSettings, outputFolder: jobFolder, overwrite: jobOverwrite) }
    }
    while let outcome = await group.next() {
        if let output = outcome.output {
            totalIn += outcome.input
            totalOut += output
            print("✓ \(outcome.name)  \(outcome.message)")
        } else {
            failures += 1
            FileHandle.standardError.write(Data("✗ \(outcome.name)  \(outcome.message)\n".utf8))
        }
        if let file = pending.next() {
            group.addTask { await convert(file, settings: jobSettings, outputFolder: jobFolder, overwrite: jobOverwrite) }
        }
    }
}

if files.count > 1, totalIn > 0 {
    let saved = Int((1 - Double(totalOut) / Double(totalIn)) * 100)
    print("\n\(files.count - failures) of \(files.count) images  \(bytes(totalIn)) → \(bytes(totalOut))  −\(saved)%")
}
exit(failures == 0 ? 0 : 1)
