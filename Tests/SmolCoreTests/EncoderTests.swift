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

@Test func fitWithOneSideLimitsOnlyThatSide() {
    #expect(ResizeOptions(mode: .fit, maxWidth: 1600, maxHeight: 0).targetSize(width: 3000, height: 6000) == (1600, 3200))
    #expect(ResizeOptions(mode: .fit, maxWidth: 0, maxHeight: 900).targetSize(width: 3600, height: 1800) == (1800, 900))
    #expect(ResizeOptions(mode: .fit, maxWidth: 0, maxHeight: 0).targetSize(width: 800, height: 600) == (800, 600))
    // The same number on both sides caps the longest edge, portrait or landscape.
    let edge = ResizeOptions(mode: .fit, maxWidth: 1000, maxHeight: 1000)
    #expect(edge.targetSize(width: 2000, height: 4000) == (500, 1000))
    #expect(edge.targetSize(width: 4000, height: 2000) == (1000, 500))
    #expect(edge.targetSize(width: 640, height: 480) == (640, 480))
}

@Test func resizeSpecs() {
    #expect(ResizeOptions(spec: "50%") == ResizeOptions(mode: .percent, percent: 50))
    #expect(ResizeOptions(spec: "1920") == ResizeOptions(mode: .fit, maxWidth: 1920, maxHeight: 1920))
    #expect(ResizeOptions(spec: "1920x1080") == ResizeOptions(mode: .fit, maxWidth: 1920, maxHeight: 1080))
    #expect(ResizeOptions(spec: "1600x") == ResizeOptions(mode: .fit, maxWidth: 1600, maxHeight: 0))
    #expect(ResizeOptions(spec: "X900") == ResizeOptions(mode: .fit, maxWidth: 0, maxHeight: 900))
    for bad in ["", "x", "0", "-5", "0%", "wide", "10x20x30", "1920xtall"] {
        #expect(ResizeOptions(spec: bad) == nil, "\(bad)")
    }
    #expect(ResizeOptions(spec: "1600x")?.allowUpscale == false)
}

@Test func resizeSummaries() {
    #expect(ResizeOptions(mode: .fit, maxWidth: 1600, maxHeight: 0).summary == "fit 1600 wide")
    #expect(ResizeOptions(mode: .fit, maxWidth: 0, maxHeight: 900).summary == "fit 900 tall")
    #expect(ResizeOptions(mode: .fit, maxWidth: 1600, maxHeight: 900).summary == "fit 1600×900")
}

@Test func encoderAppliesWidthOnlyFitWithoutUpscaling() async throws {
    let image = makeTestImage()
    let smaller = try await ImageEncoder.encode(image, settings: EncodeSettings(
        format: .jpeg, resize: ResizeOptions(mode: .fit, maxWidth: 150, maxHeight: 0)))
    #expect(smaller.width == 150 && smaller.height == 100)
    let untouched = try await ImageEncoder.encode(image, settings: EncodeSettings(
        format: .jpeg, resize: ResizeOptions(mode: .fit, maxWidth: 4000, maxHeight: 0)))
    #expect(untouched.width == 300 && untouched.height == 200)
}

@Test func responsiveWidthsParse() {
    #expect(ResponsiveSet.parseWidths("640, 1280 1920") == [640, 1280, 1920])
    #expect(ResponsiveSet.parseWidths("640w,1280W") == [640, 1280])
    #expect(ResponsiveSet.parseWidths("") == nil)
    #expect(ResponsiveSet.parseWidths("640, wide") == nil)
    #expect(ResponsiveSet.parseWidths("0") == nil)
    #expect(ResponsiveSet.parseWidths("640.5") == nil)
}

@Test func responsiveWidthsSkipAnythingWiderThanTheSource() {
    #expect(ResponsiveSet.widths([640, 1280, 1920], sourceWidth: 3200) == [640, 1280, 1920])
    #expect(ResponsiveSet.widths([1920, 640, 1280, 640], sourceWidth: 1500) == [640, 1280])
    #expect(ResponsiveSet.widths([640, 1280], sourceWidth: 1280) == [640, 1280])
    #expect(ResponsiveSet.widths([640, 1280, 1920], sourceWidth: 500) == [500])
    #expect(ResponsiveSet.widths([640], sourceWidth: 0) == [])
}

@Test func responsiveSnippet() {
    let variants = [
        ResponsiveVariant(fileName: "hero-1280w.webp", width: 1280, height: 800),
        ResponsiveVariant(fileName: "hero-640w.webp", width: 640, height: 400),
    ]
    let expected = """
    <img src="hero-1280w.webp"
         srcset="hero-640w.webp 640w, hero-1280w.webp 1280w"
         sizes="100vw" width="1280" height="800" alt="">
    """
    #expect(ResponsiveSet.snippet(variants) == expected)
    #expect(ResponsiveSet.snippet([]) == "")
    #expect(ResponsiveSet.baseName("hero", width: 640) == "hero-640w")
}

@Test func responsiveSnippetEscapesNamesAndAttributes() {
    let tag = ResponsiveSet.snippet(
        [ResponsiveVariant(fileName: "team photo, 2-640w.avif", width: 640, height: 480)],
        sizes: "(min-width: 60em) 50vw, 100vw", alt: "Tom & \"Jerry\"", pathPrefix: "images/")
    #expect(tag.contains("src=\"images/team%20photo%2C%202-640w.avif\""))
    #expect(tag.contains("srcset=\"images/team%20photo%2C%202-640w.avif 640w\""))
    #expect(tag.contains("sizes=\"(min-width: 60em) 50vw, 100vw\""))
    #expect(tag.contains("alt=\"Tom &amp; &quot;Jerry&quot;\""))
}

@Test func responsiveSetEncodesEachWidthThatFits() async throws {
    let image = makeTestImage(width: 600, height: 400)
    let settings = EncodeSettings(format: .jpeg, quality: 60, resize: ResizeOptions(mode: .percent, percent: 10))
    let results = try await ResponsiveSet.encode(image, widths: [900, 300, 150], settings: settings)
    #expect(results.map(\.width) == [150, 300])
    #expect(results.map(\.height) == [100, 200])
    for result in results {
        let decoded = try ImageDecoder.decode(data: result.data)
        #expect(decoded.width == result.width && decoded.height == result.height)
    }
    let small = try await ResponsiveSet.encode(image, widths: [1280, 1920], settings: settings)
    #expect(small.map(\.width) == [600])
}
