import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ImageInfo: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let typeIdentifier: String?

    public var formatName: String {
        guard let id = typeIdentifier, let type = UTType(id) else { return "Image" }
        return type.preferredFilenameExtension?.uppercased() ?? type.localizedDescription ?? "Image"
    }
}

public enum ImageDecoder {
    /// Reads dimensions (orientation-corrected) without decoding pixels.
    public static func info(url: URL) -> ImageInfo? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = props[kCGImagePropertyPixelWidth] as? Int,
              var height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        if let orientation = props[kCGImagePropertyOrientation] as? UInt32, orientation >= 5 {
            swap(&width, &height)
        }
        return ImageInfo(width: width, height: height, typeIdentifier: CGImageSourceGetType(source) as String?)
    }

    /// Full-resolution decode with EXIF orientation applied.
    public static func decode(url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw SmolError.unreadable(url.lastPathComponent)
        }
        return try decode(source: source, name: url.lastPathComponent)
    }

    public static func decode(data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw SmolError.unreadable("image data")
        }
        return try decode(source: source, name: "image data")
    }

    static func decode(source: CGImageSource, name: String) throws -> CGImage {
        guard CGImageSourceGetCount(source) > 0 else { throw SmolError.unreadable(name) }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = props[kCGImagePropertyOrientation] as? UInt32 ?? 1

        if orientation == 1 || width == 0 || height == 0 {
            guard let image = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            else { throw SmolError.unreadable(name) }
            return image
        }

        // The thumbnail API is the simplest way to get ImageIO to bake in the orientation.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw SmolError.unreadable(name)
        }
        return image
    }

    public static func thumbnail(url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    public static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }
}
