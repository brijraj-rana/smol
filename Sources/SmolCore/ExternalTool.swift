import Foundation

/// Optional Homebrew command-line encoders. The app works without them; they unlock WebP, JPEG XL and better PNGs.
public enum ExternalTool: String, CaseIterable, Sendable {
    case cwebp, cjxl, pngquant, oxipng

    public var brewFormula: String {
        switch self {
        case .cwebp: "webp"
        case .cjxl: "jpeg-xl"
        case .pngquant: "pngquant"
        case .oxipng: "oxipng"
        }
    }

    public var installCommand: String { "brew install \(brewFormula)" }

    public var path: String? { ToolCache.shared.paths.withLock { $0[self] } }
    public var isInstalled: Bool { path != nil }

    /// Looks for the tools again (e.g. after a `brew install` while the app is open). Returns true if anything changed.
    @discardableResult
    public static func refresh() -> Bool {
        let found = ToolCache.resolve()
        return ToolCache.shared.paths.withLock { paths in
            defer { paths = found }
            return paths != found
        }
    }
}

final class ToolCache: Sendable {
    static let shared = ToolCache()
    let paths = Locked(ToolCache.resolve())

    // Apps launched from Finder don't inherit the shell PATH, so look in the Homebrew locations explicitly.
    static func resolve() -> [ExternalTool: String] {
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs += path.split(separator: ":").map(String.init)
        }
        var found: [ExternalTool: String] = [:]
        for tool in ExternalTool.allCases {
            for dir in dirs {
                let candidate = (dir as NSString).appendingPathComponent(tool.rawValue)
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    found[tool] = candidate
                    break
                }
            }
        }
        return found
    }
}

/// Minimal lock-protected box.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

public enum SmolError: LocalizedError, Sendable {
    case unreadable(String)
    case encodeFailed(String)
    case toolMissing(ExternalTool)
    case toolFailed(ExternalTool, Int32, String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name): "Couldn't read \(name)"
        case .encodeFailed(let message): message
        case .toolMissing(let tool): "\(tool.rawValue) isn't installed. Run: \(tool.installCommand)"
        case .toolFailed(let tool, let status, let stderr):
            "\(tool.rawValue) failed (\(status)): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

enum ProcessRunner {
    static func run(_ tool: ExternalTool, _ arguments: [String]) async throws {
        guard let path = tool.path else { throw SmolError.toolMissing(tool) }
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice

        // Drain stderr while the tool runs; a full pipe would block the child forever.
        let stderr = Pipe()
        process.standardError = stderr
        let output = Locked(Data())
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                output.withLock { $0.append(chunk) }
            }
        }

        // Only our own terminate() counts as cancellation; crashes and OOM kills are real failures.
        let cancelled = Locked(false)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { finished in
                    stderr.fileHandleForReading.readabilityHandler = nil
                    if cancelled.withLock({ $0 }) {
                        continuation.resume(throwing: CancellationError())
                    } else if finished.terminationReason == .exit && finished.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        var message = String(decoding: output.withLock { $0 }, as: UTF8.self)
                        if finished.terminationReason == .uncaughtSignal {
                            message = "killed by signal \(finished.terminationStatus). " + message
                        }
                        continuation.resume(throwing: SmolError.toolFailed(tool, finished.terminationStatus, message))
                    }
                }
                do {
                    try process.run()
                    if cancelled.withLock({ $0 }) { process.terminate() }
                } catch {
                    stderr.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
            if process.isRunning { process.terminate() }
        }
    }
}
