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
      --resize <spec>     50%, 1920 (longest edge), 1920x1080 (fit within),
                          1600x (width only) or x900 (height only). Never enlarges.
      --srcset            responsive set: one file per width (640, 1280, 1920),
                          named photo-640w.webp, and an <img srcset> tag on stdout
      --widths <list>     widths for the set, e.g. 480,960,1440 (implies --srcset)
      --sizes <value>     sizes attribute for the tag                        (default: 100vw)
      --effort <level>    fast, balanced, best                               (default: balanced)
  -o, --output <folder>   write here instead of next to each original
      --overwrite         replace existing files instead of writing "name 2.ext"
  -h, --help

EXAMPLES
  smol photo.jpg -f avif -q 45
  smol ~/Downloads/convert -f avif -q 45 --resize 50% -o ~/Downloads/avif
  smol hero.png -f webp --max-size 200kb
  smol hero.png -f webp --resize 1600
  smol hero.png -f avif --srcset | pbcopy
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
var setWidths: [Int]?
var sizes = ResponsiveSet.defaultSizes

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
        guard let resize = ResizeOptions(spec: nextValue(for: argument)) else {
            fail("--resize expects 50%, 1920, 1920x1080, 1600x or x900")
        }
        settings.resize = resize
    case "--srcset":
        setWidths = setWidths ?? ResponsiveSet.defaultWidths
    case "--widths":
        guard let widths = ResponsiveSet.parseWidths(nextValue(for: argument)) else { fail("--widths expects something like 640,1280,1920") }
        setWidths = widths
    case "--sizes":
        sizes = nextValue(for: argument)
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

/// Writes `data` as `base.ext` in `folder` and returns where it went.
func write(_ data: Data, base: String, format: OutputFormat, folder: URL, source: URL, overwrite: Bool) throws -> URL {
    var destination = folder.appendingPathComponent(base).appendingPathExtension(format.fileExtension)
    // Never clobber the source, and never clobber anything else unless asked.
    if !overwrite || destination.standardizedFileURL == source.standardizedFileURL {
        destination = FolderScanner.uniqueURL(in: folder, baseName: base, fileExtension: format.fileExtension)
    }
    try data.write(to: destination, options: .atomic)
    return destination
}

func convert(_ file: URL, settings: EncodeSettings, outputFolder: URL?, overwrite: Bool) async -> Outcome {
    let inputSize = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    do {
        let encoded = try await ImageEncoder.encode(url: file, settings: settings)
        let folder = outputFolder ?? file.deletingLastPathComponent()
        let base = file.deletingPathExtension().lastPathComponent
        let destination = try write(encoded.data, base: base, format: settings.format, folder: folder,
                                    source: file, overwrite: overwrite)
        let saved = inputSize > 0 ? Int((1 - Double(encoded.byteCount) / Double(inputSize)) * 100) : 0
        return Outcome(name: file.lastPathComponent, input: inputSize, output: encoded.byteCount,
                       message: "\(bytes(inputSize)) → \(bytes(encoded.byteCount))  \(saved >= 0 ? "−" : "+")\(abs(saved))%  \(destination.lastPathComponent)")
    } catch {
        return Outcome(name: file.lastPathComponent, input: inputSize, output: nil, message: error.localizedDescription)
    }
}

/// One image at several widths. The outcome carries the tag for stdout.
func convertSet(_ file: URL, widths: [Int], sizes: String, settings: EncodeSettings,
                outputFolder: URL?, overwrite: Bool) async -> (Outcome, String?) {
    let inputSize = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    do {
        let image = try ImageDecoder.decode(url: file)
        let encoded = try await ResponsiveSet.encode(image, widths: widths, settings: settings)
        let folder = outputFolder ?? file.deletingLastPathComponent()
        let base = file.deletingPathExtension().lastPathComponent
        var variants: [ResponsiveVariant] = []
        var total: Int64 = 0
        var parts: [String] = []
        for result in encoded {
            let destination = try write(result.data, base: ResponsiveSet.baseName(base, width: result.width),
                                        format: settings.format, folder: folder, source: file, overwrite: overwrite)
            variants.append(ResponsiveVariant(fileName: destination.lastPathComponent, width: result.width, height: result.height))
            total += result.byteCount
            parts.append("\(result.width)w \(bytes(result.byteCount))")
        }
        return (Outcome(name: file.lastPathComponent, input: inputSize, output: total,
                        message: "\(bytes(inputSize)) → \(parts.joined(separator: " · "))"),
                ResponsiveSet.snippet(variants, sizes: sizes))
    } catch {
        return (Outcome(name: file.lastPathComponent, input: inputSize, output: nil, message: error.localizedDescription), nil)
    }
}

var totalIn: Int64 = 0, totalOut: Int64 = 0, failures = 0
let limit = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
let jobSettings = settings, jobFolder = outputFolder, jobOverwrite = overwrite

if let setWidths {
    // Progress goes to stderr so stdout is only the tags: `smol hero.png --srcset | pbcopy`.
    let jobSizes = sizes
    var tags: [String] = []
    for file in files {
        let (outcome, tag) = await convertSet(file, widths: setWidths, sizes: jobSizes, settings: jobSettings,
                                              outputFolder: jobFolder, overwrite: jobOverwrite)
        if let tag {
            tags.append(tag)
            FileHandle.standardError.write(Data("✓ \(outcome.name)  \(outcome.message)\n".utf8))
        } else {
            failures += 1
            FileHandle.standardError.write(Data("✗ \(outcome.name)  \(outcome.message)\n".utf8))
        }
    }
    if !tags.isEmpty { print(tags.joined(separator: "\n\n")) }
    exit(failures == 0 ? 0 : 1)
}

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
