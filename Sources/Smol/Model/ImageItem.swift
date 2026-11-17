import CoreGraphics
import Foundation
import Observation
import SmolCore

@MainActor @Observable
final class ImageItem: Identifiable {
    let id = UUID()
    let url: URL
    let fileSize: Int64

    var info: ImageInfo?
    var thumbnail: CGImage?
    var loadError: String?

    /// Full-resolution original, only kept for the selected item.
    var original: CGImage?
    /// Decoded compressed output, only kept for the selected item.
    var preview: CGImage?

    var result: EncodedImage?
    var resultSettings: EncodeSettings?
    var error: String?
    var encodingCount = 0

    init(url: URL, fileSize: Int64) {
        self.url = url
        self.fileSize = fileSize
    }

    var name: String { url.lastPathComponent }
    var baseName: String { url.deletingPathExtension().lastPathComponent }
    var isEncoding: Bool { encodingCount > 0 }

    func isCurrent(_ settings: EncodeSettings) -> Bool { resultSettings == settings }

    func currentResult(_ settings: EncodeSettings) -> EncodedImage? {
        isCurrent(settings) ? result : nil
    }

    /// Fraction saved (0.87 = 87% smaller). Negative when the output is bigger.
    func savings(_ settings: EncodeSettings) -> Double? {
        guard let result = currentResult(settings), fileSize > 0 else { return nil }
        return 1 - Double(result.byteCount) / Double(fileSize)
    }

    func releaseHeavyData() {
        original = nil
        preview = nil
    }
}
