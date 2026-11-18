import CoreGraphics
import Foundation

/// One file of a responsive set, as it ends up on disk.
public struct ResponsiveVariant: Equatable, Sendable {
    public let fileName: String
    public let width: Int
    public let height: Int

    public init(fileName: String, width: Int, height: Int) {
        self.fileName = fileName
        self.width = width
        self.height = height
    }
}

/// One image at several widths, plus the `<img srcset sizes>` tag that uses them.
public enum ResponsiveSet {
    public static let defaultWidths = [640, 1280, 1920]
    public static let defaultSizes = "100vw"

    /// Reads "640, 1280 1920" or "640w,1280w". Nil if the text is empty or anything isn't a positive whole number.
    public static func parseWidths(_ text: String) -> [Int]? {
        let tokens = text.lowercased().split { $0 == "," || $0 == " " }
        var widths: [Int] = []
        for token in tokens {
            let digits = token.hasSuffix("w") ? token.dropLast() : token
            guard let width = Int(digits), width > 0 else { return nil }
            widths.append(width)
        }
        return widths.isEmpty ? nil : widths
    }

    /// Ascending, without duplicates, and never wider than the source.
    /// A source narrower than every requested width is kept once at its own width.
    public static func widths(_ requested: [Int], sourceWidth: Int) -> [Int] {
        guard sourceWidth > 0 else { return [] }
        let fitting = Set(requested.filter { $0 > 0 && $0 <= sourceWidth }).sorted()
        return fitting.isEmpty ? [sourceWidth] : fitting
    }

    /// "hero" at 640 → "hero-640w".
    public static func baseName(_ name: String, width: Int) -> String { "\(name)-\(width)w" }

    /// Encodes `image` once per width, smallest first. Widths replace whatever resize the settings carry.
    public static func encode(_ image: CGImage, widths requested: [Int],
                              settings: EncodeSettings) async throws -> [EncodedImage] {
        var results: [EncodedImage] = []
        for width in widths(requested, sourceWidth: image.width) {
            try Task.checkCancellation()
            var variant = settings
            variant.resize = ResizeOptions(mode: .fit, maxWidth: width, maxHeight: 0)
            results.append(try await ImageEncoder.encode(image, settings: variant))
        }
        return results
    }

    /// An `<img>` tag ready to paste. The largest file is the fallback `src` and sets `width` and `height`.
    /// `pathPrefix` goes in front of every file name, e.g. "images/" or a CDN URL.
    public static func snippet(_ variants: [ResponsiveVariant], sizes: String = defaultSizes,
                               alt: String = "", pathPrefix: String = "") -> String {
        let sorted = variants.sorted { $0.width < $1.width }
        guard let largest = sorted.last else { return "" }
        func address(_ variant: ResponsiveVariant) -> String {
            let name = variant.fileName.addingPercentEncoding(withAllowedCharacters: fileNameAllowed) ?? variant.fileName
            return escape(pathPrefix + name)
        }
        let srcset = sorted.map { "\(address($0)) \($0.width)w" }.joined(separator: ", ")
        return """
        <img src="\(address(largest))"
             srcset="\(srcset)"
             sizes="\(escape(sizes))" width="\(largest.width)" height="\(largest.height)" alt="\(escape(alt))">
        """
    }

    /// Spaces and commas would split a srcset entry, so they are percent-encoded along with everything unusual.
    private static let fileNameAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
