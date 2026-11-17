// Renders Resources/AppIcon.icns: the dial, with a big outline shrinking to a small solid tile.
// Usage: swift scripts/make-icon.swift [repo root]
import AppKit

func drawIcon(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let ctx = NSGraphicsContext.current!.cgContext
        let s = size / 1024
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
            CGColor(colorSpace: srgb, components: [r, g, b, a])!
        }
        let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let tilePath = CGPath(roundedRect: tile, cornerWidth: 186 * s, cornerHeight: 186 * s, transform: nil)

        // Drop shadow + graphite body.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: color(0, 0, 0, 0.35))
        ctx.addPath(tilePath); ctx.setFillColor(color(0.1, 0.1, 0.11)); ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(tilePath); ctx.clip()
        let body = CGGradient(colorsSpace: srgb, colors: [color(0.20, 0.20, 0.22), color(0.07, 0.07, 0.08)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(body, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
        // Soft light from the top-left.
        let glow = CGGradient(colorsSpace: srgb, colors: [color(1, 1, 1, 0.10), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: tile.minX + 220 * s, y: tile.maxY - 160 * s), startRadius: 0,
                               endCenter: CGPoint(x: tile.minX + 220 * s, y: tile.maxY - 160 * s), endRadius: 620 * s, options: [])
        ctx.restoreGState()

        // Hairline edge highlight.
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 1.5 * s, dy: 1.5 * s), cornerWidth: 184 * s, cornerHeight: 184 * s, transform: nil))
        ctx.setStrokeColor(color(1, 1, 1, 0.10)); ctx.setLineWidth(3 * s); ctx.strokePath()
        ctx.restoreGState()

        let center = CGPoint(x: 512 * s, y: 512 * s)
        let radius = 286 * s

        // Dial ring.
        ctx.setStrokeColor(color(1, 1, 1, 0.16))
        ctx.setLineWidth(10 * s)
        ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))

        // Indicator arc (top-right), the one accent.
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 26 * s, color: color(0.25, 0.9, 0.55, 0.55))
        ctx.setStrokeColor(color(0.27, 0.87, 0.55))
        ctx.setLineWidth(26 * s)
        ctx.setLineCap(.round)
        ctx.addArc(center: center, radius: radius, startAngle: .pi * 0.11, endAngle: .pi * 0.39, clockwise: false)
        ctx.strokePath()
        ctx.restoreGState()

        // Original size: a dashed outline. Result: a small solid tile tucked in its corner.
        let big = CGRect(x: center.x - 150 * s, y: center.y - 150 * s, width: 300 * s, height: 300 * s)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: big, cornerWidth: 58 * s, cornerHeight: 58 * s, transform: nil))
        ctx.setStrokeColor(color(1, 1, 1, 0.30)); ctx.setLineWidth(11 * s)
        ctx.setLineDash(phase: 0, lengths: [26 * s, 22 * s]); ctx.setLineCap(.round)
        ctx.strokePath()
        ctx.restoreGState()

        let small = CGRect(x: big.minX, y: big.minY, width: 156 * s, height: 156 * s)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6 * s), blur: 18 * s, color: color(0, 0, 0, 0.45))
        ctx.addPath(CGPath(roundedRect: small, cornerWidth: 40 * s, cornerHeight: 40 * s, transform: nil))
        ctx.setFillColor(color(0.97, 0.97, 0.98)); ctx.fillPath()
        ctx.restoreGState()
        return true
    }
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        drawIcon(size: CGFloat(px)).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let output = root.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run(); task.waitUntilExit()
let docs = root.appendingPathComponent("docs")
try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
try? FileManager.default.removeItem(at: docs.appendingPathComponent("icon.png"))
try FileManager.default.copyItem(at: iconset.appendingPathComponent("icon_256x256@2x.png"), to: docs.appendingPathComponent("icon.png"))
print("Wrote \(output.path)")
