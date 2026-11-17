import Foundation
import ImageIO

/// Every format Smol can write.
public enum OutputFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case avif, webp, jxl, heic, jpeg, png, tiff, gif, bmp

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .avif: "AVIF"
        case .webp: "WebP"
        case .jxl: "JPEG XL"
        case .heic: "HEIC"
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .tiff: "TIFF"
        case .gif: "GIF"
        case .bmp: "BMP"
        }
    }

    public var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        default: rawValue
        }
    }

    public var symbol: String {
        switch self {
        case .avif: "sparkles"
        case .webp: "globe"
        case .jxl: "wand.and.stars"
        case .heic: "camera"
        case .jpeg: "photo"
        case .png: "square.on.square.dashed"
        case .tiff: "doc.richtext"
        case .gif: "play.rectangle"
        case .bmp: "square.grid.3x3"
        }
    }

    public var blurb: String {
        switch self {
        case .avif: "Smallest files for photos. Supported by every modern browser."
        case .webp: "Great all-rounder for the web, with transparency support."
        case .jxl: "Next-gen format with excellent quality. Limited browser support."
        case .heic: "Apple's photo format. Small files, good for Apple devices."
        case .jpeg: "Universal photo format. No transparency."
        case .png: "Lossless with transparency. Best for screenshots and graphics."
        case .tiff: "Lossless, print-oriented. Large files."
        case .gif: "256 colors. Only use for legacy compatibility."
        case .bmp: "Uncompressed bitmap."
        }
    }

    public var supportsQuality: Bool { [.avif, .webp, .jxl, .heic, .jpeg].contains(self) }
    public var supportsLossless: Bool { [.webp, .jxl].contains(self) }
    public var supportsAlpha: Bool { ![.jpeg, .bmp].contains(self) }
    public var supportsEffort: Bool { [.webp, .jxl].contains(self) || (self == .png && ExternalTool.oxipng.isInstalled) }

    /// UTI used when the format is encoded through Apple's ImageIO.
    public var imageIOType: String? {
        switch self {
        case .avif: "public.avif"
        case .heic: "public.heic"
        case .jpeg: "public.jpeg"
        case .png: "public.png"
        case .tiff: "public.tiff"
        case .gif: "com.compuserve.gif"
        case .bmp: "com.microsoft.bmp"
        case .webp, .jxl: nil
        }
    }

    /// Command-line encoder this format needs, if ImageIO can't write it.
    public var requiredTool: ExternalTool? {
        switch self {
        case .webp: .cwebp
        case .jxl: .cjxl
        default: nil
        }
    }

    public var isAvailable: Bool {
        if let tool = requiredTool { return tool.isInstalled }
        guard let type = imageIOType else { return false }
        return ImageIOSupport.encodableTypes.contains(type)
    }
}

enum ImageIOSupport {
    static let encodableTypes: Set<String> = {
        Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
    }()
}
