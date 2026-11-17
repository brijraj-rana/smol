import Foundation

public enum Effort: String, CaseIterable, Identifiable, Codable, Sendable {
    case fast, balanced, best
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public struct ResizeOptions: Equatable, Codable, Sendable {
    public enum Mode: String, CaseIterable, Identifiable, Codable, Sendable {
        case original, percent, fit
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .original: "Original"
            case .percent: "Scale"
            case .fit: "Fit within"
            }
        }
    }

    public var mode: Mode = .original
    public var percent: Double = 50
    public var maxWidth: Int = 1920
    public var maxHeight: Int = 1920
    public var allowUpscale = false

    public init(mode: Mode = .original, percent: Double = 50, maxWidth: Int = 1920, maxHeight: Int = 1920, allowUpscale: Bool = false) {
        self.mode = mode
        self.percent = percent
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.allowUpscale = allowUpscale
    }

    public func targetSize(width: Int, height: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (width, height) }
        let scale: Double
        switch mode {
        case .original:
            return (width, height)
        case .percent:
            scale = min(max(percent, 1), 400) / 100
        case .fit:
            let s = min(Double(max(maxWidth, 1)) / Double(width), Double(max(maxHeight, 1)) / Double(height))
            scale = allowUpscale ? s : min(s, 1)
        }
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    public var summary: String {
        switch mode {
        case .original: "original size"
        case .percent: "\(Int(percent))%"
        case .fit: "fit \(maxWidth)×\(maxHeight)"
        }
    }
}

public struct EncodeSettings: Equatable, Codable, Sendable {
    public var format: OutputFormat = .webp
    /// 1...100
    public var quality: Double = 75
    public var lossless = false
    public var effort: Effort = .balanced
    public var resize = ResizeOptions()
    /// PNG only: quantize to a palette with pngquant.
    public var reduceColors = false
    public var colors = 256
    /// When set, quality is chosen automatically so the file fits in this many kilobytes.
    public var targetKB: Int?

    public init(format: OutputFormat = .webp, quality: Double = 75, lossless: Bool = false, effort: Effort = .balanced,
                resize: ResizeOptions = ResizeOptions(), reduceColors: Bool = false, colors: Int = 256,
                targetKB: Int? = nil) {
        self.targetKB = targetKB
        self.format = format
        self.quality = quality
        self.lossless = lossless
        self.effort = effort
        self.resize = resize
        self.reduceColors = reduceColors
        self.colors = colors
    }

    /// Lossless only matters for formats that support it.
    public var isLossless: Bool { format.supportsLossless && lossless }

    /// Target size in bytes; only applies to lossy formats with a quality setting.
    public var targetBytes: Int? {
        guard format.supportsQuality, !isLossless, let targetKB else { return nil }
        return max(targetKB, 1) * 1000
    }

    public var summary: String {
        var parts = [format.displayName]
        if isLossless { parts.append("lossless") }
        else if targetBytes != nil { parts.append("≤\(targetKB ?? 0) KB") }
        else if format.supportsQuality { parts.append("q\(Int(quality))") }
        if format == .png && reduceColors { parts.append("\(colors) colors") }
        if resize.mode != .original { parts.append(resize.summary) }
        return parts.joined(separator: " · ")
    }
}
