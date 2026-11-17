import CoreGraphics
import Foundation
import Testing
@testable import SmolCore

/// A 300×200 gradient with a transparent corner, so alpha handling is exercised.
private func makeTestImage(width: Int = 300, height: Int = 200) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for x in 0..<width {
        context.setFillColor(CGColor(srgbRed: Double(x) / Double(width), green: 0.4, blue: 1 - Double(x) / Double(width), alpha: 1))
        context.fill(CGRect(x: x, y: 0, width: 1, height: height))
    }
    context.clear(CGRect(x: 0, y: 0, width: 40, height: 40))
    return context.makeImage()!
}

@Test func resizeFitKeepsAspectAndNeverUpscalesByDefault() {
    var resize = ResizeOptions(mode: .fit, maxWidth: 1000, maxHeight: 1000)
    #expect(resize.targetSize(width: 4000, height: 3000) == (1000, 750))
    #expect(resize.targetSize(width: 400, height: 300) == (400, 300))
    resize.allowUpscale = true
    #expect(resize.targetSize(width: 400, height: 300) == (1000, 750))
}

@Test func resizePercent() {
    let resize = ResizeOptions(mode: .percent, percent: 50)
    #expect(resize.targetSize(width: 301, height: 200) == (151, 100))
}

@Test(arguments: OutputFormat.allCases.filter(\.isAvailable))
func encodesAndDecodesBack(format: OutputFormat) async throws {
    let settings = EncodeSettings(format: format, quality: 60, resize: ResizeOptions(mode: .percent, percent: 50))
    let encoded = try await ImageEncoder.encode(makeTestImage(), settings: settings)
    #expect(encoded.data.count > 0)
    #expect(encoded.width == 150 && encoded.height == 100)
    let decoded = try ImageDecoder.decode(data: encoded.data)
    #expect(decoded.width == 150 && decoded.height == 100)
}

@Test func jpegFlattensTransparency() async throws {
    let encoded = try await ImageEncoder.encode(makeTestImage(), settings: EncodeSettings(format: .jpeg))
    let decoded = try ImageDecoder.decode(data: encoded.data)
    #expect(!ImageDecoder.hasAlpha(decoded))
}

@Test func lowerQualityIsSmaller() async throws {
    let image = makeTestImage(width: 600, height: 400)
    let high = try await ImageEncoder.encode(image, settings: EncodeSettings(format: .jpeg, quality: 95))
    let low = try await ImageEncoder.encode(image, settings: EncodeSettings(format: .jpeg, quality: 20))
    #expect(low.data.count < high.data.count)
}

@Test func folderScannerFindsImagesAndSkipsNestedOutput() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("smol-scan-\(UUID().uuidString)")
    let nested = root.appendingPathComponent("sub")
    let output = root.appendingPathComponent("out")
    for dir in [root, nested, output] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    defer { try? FileManager.default.removeItem(at: root) }
    for url in [root.appendingPathComponent("a.jpg"), nested.appendingPathComponent("b.PNG"),
                output.appendingPathComponent("c.avif"), root.appendingPathComponent("notes.txt")] {
        try Data([0]).write(to: url)
    }
    let names = FolderScanner.imageFiles(in: root, recursive: true, excluding: output).map(\.lastPathComponent)
    #expect(names == ["a.jpg", "b.PNG"])
    #expect(FolderScanner.imageFiles(in: root, recursive: false, excluding: output).map(\.lastPathComponent) == ["a.jpg"])
}

@Test func plannedOutputsMirrorSubfoldersAndAvoidCollisions() {
    let input = URL(fileURLWithPath: "/in")
    let output = URL(fileURLWithPath: "/out")
    let files = ["/in/a/photo.jpg", "/in/b/photo.jpg", "/in/x.png", "/in/x.JPG", "/in/solo.heic"].map { URL(fileURLWithPath: $0) }
    let plan = FolderScanner.plannedOutputs(for: files, inputRoot: input, outputRoot: output, format: .avif)
    #expect(plan[files[0]]?.path == "/out/a/photo.avif")
    #expect(plan[files[1]]?.path == "/out/b/photo.avif")
    #expect(plan[files[2]]?.path == "/out/x-png.avif")
    #expect(plan[files[3]]?.path == "/out/x-jpg.avif")
    #expect(plan[files[4]]?.path == "/out/solo.avif")
    #expect(Set(plan.values).count == files.count)
}

@Test func opaqueImagesStayOpaque() async throws {
    let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    let encoded = try await ImageEncoder.encode(context.makeImage()!, settings: EncodeSettings(format: .png))
    #expect(!ImageDecoder.hasAlpha(try ImageDecoder.decode(data: encoded.data)))
}

@Test func toolFailureIsNotReportedAsCancellation() async {
    // cwebp exits non-zero on a missing input; that must surface as a tool failure.
    guard ExternalTool.cwebp.isInstalled else { return }
    await #expect(throws: SmolError.self) {
        try await ProcessRunner.run(.cwebp, ["-quiet", "/nonexistent.png", "-o", "/tmp/x.webp"])
    }
}

@Test func targetSizeFitsUnderTheLimit() async throws {
    // Noise compresses badly, so the limit forces a real search.
    let width = 400, height = 300
    var generator = SystemRandomNumberGenerator()
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for index in stride(from: 0, to: pixels.count, by: 4) {
        pixels[index] = UInt8.random(in: 0...255, using: &generator)
        pixels[index + 1] = UInt8.random(in: 0...255, using: &generator)
        pixels[index + 2] = UInt8.random(in: 0...255, using: &generator)
    }
    let image = pixels.withUnsafeMutableBytes { buffer in
        CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
    }
    let unconstrained = try await ImageEncoder.encode(image, settings: EncodeSettings(format: .jpeg, quality: 95))
    let limited = try await ImageEncoder.encode(image, settings: EncodeSettings(format: .jpeg, quality: 95, targetKB: 30))
    #expect(unconstrained.data.count > 30_000)
    #expect(limited.data.count <= 30_000)
    #expect((limited.quality ?? 100) < 95)
}

@Test(arguments: OutputFormat.allCases.filter { $0.isAvailable && $0.supportsQuality })
func qualityExtremesEncode(format: OutputFormat) async throws {
    for quality in [1.0, 100.0] {
        let encoded = try await ImageEncoder.encode(makeTestImage(), settings: EncodeSettings(format: format, quality: quality))
        #expect(encoded.data.count > 0)
    }
}
