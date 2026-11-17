import CoreGraphics
import Foundation
import ImageIO

public struct EncodedImage: Sendable {
    public let data: Data
    public let width: Int
    public let height: Int
    public let format: OutputFormat
    /// The quality that was actually used (differs from the setting when a target size is set). Nil for lossless output.
    public let quality: Int?

    public var byteCount: Int64 { Int64(data.count) }
}

/// One implementation per output format.
///
/// To add a format: add a case to `OutputFormat`, write a `FormatEncoder`, and return it from `EncoderRegistry`.
/// Nothing in the app or CLI needs to change.
public protocol FormatEncoder: Sendable {
    /// `image` is already resized, flattened if needed, and in 8-bit RGB(A).
    func encode(_ image: CGImage, settings: EncodeSettings) async throws -> Data
}

public enum EncoderRegistry {
    public static func encoder(for format: OutputFormat) -> any FormatEncoder {
        switch format {
        case .webp: WebPEncoder()
        case .jxl: JPEGXLEncoder()
        case .png: PNGEncoder()
        case .avif, .heic, .jpeg, .tiff, .gif, .bmp: ImageIOEncoder(format: format)
        }
    }
}

public enum ImageEncoder {
    public static func encode(url: URL, settings: EncodeSettings) async throws -> EncodedImage {
        let image = try ImageDecoder.decode(url: url)
        return try await encode(image, settings: settings)
    }

    /// Resizes, flattens if needed, and encodes. Metadata (EXIF, GPS) is always stripped; the color profile is kept.
    public static func encode(_ image: CGImage, settings: EncodeSettings) async throws -> EncodedImage {
        let format = settings.format
        let size = settings.resize.targetSize(width: image.width, height: image.height)
        let flatten = !format.supportsAlpha && ImageDecoder.hasAlpha(image)
        let prepared = try ImageProcessor.render(
            image, width: size.width, height: size.height,
            background: flatten ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1) : nil)
        try Task.checkCancellation()

        let encoder = EncoderRegistry.encoder(for: format)
        let data: Data
        var quality: Int? = format.supportsQuality && !settings.isLossless ? Int(settings.quality) : nil
        if let limit = settings.targetBytes {
            (data, quality) = try await fit(prepared, under: limit, settings: settings, encoder: encoder)
        } else {
            data = try await encoder.encode(prepared, settings: settings)
        }
        return EncodedImage(data: data, width: size.width, height: size.height, format: format, quality: quality)
    }

    /// Binary-searches for the highest quality whose output fits in `limit` bytes (about 7 encodes).
    /// If even quality 1 is too big, returns the smallest result found.
    private static func fit(_ image: CGImage, under limit: Int, settings: EncodeSettings,
                            encoder: any FormatEncoder) async throws -> (Data, Int?) {
        var low = 1, high = 100
        var best: (Data, Int)?
        var smallest: (Data, Int)?
        while low <= high {
            try Task.checkCancellation()
            let mid = (low + high) / 2
            var attempt = settings
            attempt.quality = Double(mid)
            let data = try await encoder.encode(image, settings: attempt)
            if smallest == nil || data.count < smallest!.0.count { smallest = (data, mid) }
            if data.count <= limit {
                best = (data, mid)
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        let chosen = best ?? smallest!
        return (chosen.0, chosen.1)
    }
}

// MARK: - Encoders

/// AVIF, HEIC, JPEG, TIFF, GIF, BMP (and the PNG base) through Apple's ImageIO.
struct ImageIOEncoder: FormatEncoder {
    let format: OutputFormat

    func encode(_ image: CGImage, settings: EncodeSettings) async throws -> Data {
        try Self.write(image, format: format, quality: settings.quality)
    }

    static func write(_ image: CGImage, format: OutputFormat, quality: Double?) throws -> Data {
        guard let type = format.imageIOType, format.isAvailable else {
            throw SmolError.encodeFailed("\(format.displayName) can't be written on this Mac")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else {
            throw SmolError.encodeFailed("Couldn't create a \(format.displayName) encoder")
        }
        var properties: [CFString: Any] = [:]
        if let quality, format.supportsQuality {
            // ImageIO's AVIF encoder fails outright at 1.0, so "100" means 0.99 there.
            let ceiling = format == .avif ? 0.99 : 1.0
            properties[kCGImageDestinationLossyCompressionQuality] = min(max(quality / 100, 0), ceiling)
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw SmolError.encodeFailed("\(format.displayName) encoding failed")
        }
        return data as Data
    }
}

struct WebPEncoder: FormatEncoder {
    func encode(_ image: CGImage, settings: EncodeSettings) async throws -> Data {
        guard ExternalTool.cwebp.isInstalled else { throw SmolError.toolMissing(.cwebp) }
        return try await TempDirectory.with { dir in
            let input = dir.appendingPathComponent("in.png")
            let output = dir.appendingPathComponent("out.webp")
            try ImageIOEncoder.write(image, format: .png, quality: nil).write(to: input)
            let method = switch settings.effort { case .fast: "2"; case .balanced: "4"; case .best: "6" }
            var args = ["-quiet", "-metadata", "icc", "-m", method]
            if settings.lossless {
                args += ["-lossless"]
            } else {
                args += ["-q", String(Int(settings.quality)), "-alpha_q", "100"]
            }
            args += [input.path, "-o", output.path]
            try await ProcessRunner.run(.cwebp, args)
            return try Data(contentsOf: output)
        }
    }
}

struct JPEGXLEncoder: FormatEncoder {
    func encode(_ image: CGImage, settings: EncodeSettings) async throws -> Data {
        guard ExternalTool.cjxl.isInstalled else { throw SmolError.toolMissing(.cjxl) }
        return try await TempDirectory.with { dir in
            let input = dir.appendingPathComponent("in.png")
            let output = dir.appendingPathComponent("out.jxl")
            try ImageIOEncoder.write(image, format: .png, quality: nil).write(to: input)
            let effort = switch settings.effort { case .fast: "3"; case .balanced: "7"; case .best: "9" }
            var args = [input.path, output.path, "--quiet", "-e", effort]
            args += settings.lossless ? ["-d", "0"] : ["-q", String(Int(settings.quality))]
            try await ProcessRunner.run(.cjxl, args)
            return try Data(contentsOf: output)
        }
    }
}

/// ImageIO PNG, then optional palette reduction (pngquant) and lossless optimization (oxipng).
struct PNGEncoder: FormatEncoder {
    func encode(_ image: CGImage, settings: EncodeSettings) async throws -> Data {
        let base = try ImageIOEncoder.write(image, format: .png, quality: nil)
        let quantize = settings.reduceColors && ExternalTool.pngquant.isInstalled
        let optimize = ExternalTool.oxipng.isInstalled
        guard quantize || optimize else { return base }

        return try await TempDirectory.with { dir in
            var current = dir.appendingPathComponent("in.png")
            try base.write(to: current)
            if quantize {
                let output = dir.appendingPathComponent("quant.png")
                let speed = switch settings.effort { case .fast: "8"; case .balanced: "4"; case .best: "1" }
                let colors = String(min(max(settings.colors, 2), 256))
                try await ProcessRunner.run(.pngquant, ["--force", "--speed", speed, "--output", output.path, colors, "--", current.path])
                current = output
            }
            if optimize {
                let output = dir.appendingPathComponent("opt.png")
                let level = switch settings.effort { case .fast: "1"; case .balanced: "2"; case .best: "4" }
                try await ProcessRunner.run(.oxipng, ["--quiet", "-o", level, "--strip", "safe", "--out", output.path, current.path])
                current = output
            }
            return try Data(contentsOf: current)
        }
    }
}

enum TempDirectory {
    static func with<T>(_ body: (URL) async throws -> T) async throws -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("smol-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try await body(dir)
    }
}

public enum ImageProcessor {
    /// Draws into an 8-bit RGB(A) bitmap at the target size. Flattens onto `background` when given.
    public static func render(_ image: CGImage, width: Int, height: Int, background: CGColor?) throws -> CGImage {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let preferred = (image.colorSpace?.model == .rgb) ? image.colorSpace! : srgb
        // Opaque sources stay opaque: an unused alpha channel makes every output bigger.
        let keepAlpha = background == nil && ImageDecoder.hasAlpha(image)
        let alphaInfo: CGImageAlphaInfo = keepAlpha ? .premultipliedLast : .noneSkipLast

        func makeContext(_ space: CGColorSpace) -> CGContext? {
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                      space: space, bitmapInfo: alphaInfo.rawValue)
        }
        guard let context = makeContext(preferred) ?? makeContext(srgb) else {
            throw SmolError.encodeFailed("Couldn't allocate a \(width)×\(height) canvas")
        }
        context.interpolationQuality = .high
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if let background {
            context.setFillColor(background)
            context.fill(rect)
        }
        context.draw(image, in: rect)
        guard let output = context.makeImage() else {
            throw SmolError.encodeFailed("Couldn't render the resized image")
        }
        return output
    }
}
