import AppKit
import Foundation

/// App-wide preferences (⌘,). Encode settings live separately in `EncodeSettings`.
struct Preferences: Codable, Equatable {
    enum Destination: String, Codable, CaseIterable, Identifiable {
        case ask, besideOriginal, folder
        var id: String { rawValue }
    }

    enum Appearance: String, Codable, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String { rawValue.capitalized }

        var nsAppearance: NSAppearance? {
            switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    var destination: Destination = .ask
    var folderPath: String?
    /// Added to file names on save, e.g. "-smol" → photo-smol.webp. Empty keeps the original name.
    var suffix = ""
    var revealAfterSave = true
    var appearance: Appearance = .system

    init() {}

    // Tolerant decoding, so adding a preference never resets the ones already saved.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        destination = try values.decodeIfPresent(Destination.self, forKey: .destination) ?? .ask
        folderPath = try values.decodeIfPresent(String.self, forKey: .folderPath)
        suffix = try values.decodeIfPresent(String.self, forKey: .suffix) ?? ""
        revealAfterSave = try values.decodeIfPresent(Bool.self, forKey: .revealAfterSave) ?? true
        appearance = try values.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .system
    }

    var folderURL: URL? { folderPath.map { URL(fileURLWithPath: $0) } }

    /// Short label for the current destination, e.g. "Ask each time" or "~/Pictures/Smol".
    var destinationLabel: String {
        switch destination {
        case .ask: "Ask each time"
        case .besideOriginal: "Next to originals"
        case .folder: folderPath.map { $0.replacingOccurrences(of: NSHomeDirectory(), with: "~") } ?? "Choose folder…"
        }
    }

    /// File-name-safe version of the suffix.
    var cleanSuffix: String {
        suffix.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined().trimmingCharacters(in: .whitespaces)
    }
}
