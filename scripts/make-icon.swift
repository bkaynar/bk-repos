// Uygulama ikonunu çizer ve .icns dosyasına dönüştürür.
// Kullanım: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("BKRepos-\(UUID().uuidString)")
    .appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func symbol(_ name: String, pointSize: CGFloat) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(px)
    // macOS ikon ızgarası: 1024'lük tuvalde 824'lük gövde.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.white.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Üstte mor, altta turuncu.
    NSGradient(
        starting: NSColor(srgbRed: 0.48, green: 0.25, blue: 0.90, alpha: 1),
        ending: NSColor(srgbRed: 0.98, green: 0.52, blue: 0.16, alpha: 1)
    )!.draw(in: path, angle: -90)

    // Ortada dal simgesi; sağ üstte "korunan iş"i anlatan küçük kalkan.
    if let branch = symbol("arrow.triangle.branch", pointSize: s * 0.40) {
        let size = branch.size
        branch.draw(in: NSRect(x: (s - size.width) / 2 - s * 0.03, y: (s - size.height) / 2 - s * 0.02, width: size.width, height: size.height))
    }
    if let shield = symbol("checkmark.shield.fill", pointSize: s * 0.15) {
        let size = shield.size
        shield.draw(in: NSRect(x: body.maxX - size.width - s * 0.10, y: body.maxY - size.height - s * 0.10, width: size.width, height: size.height))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try render(points * scale).write(to: iconset.appendingPathComponent(name))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil başarısız oldu") }
print("İkon: \(output.path)")
print("Önizleme: \(iconset.appendingPathComponent("icon_512x512@2x.png").path)")
