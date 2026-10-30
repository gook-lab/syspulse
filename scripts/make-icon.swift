// 앱 아이콘을 그려 iconset 으로 저장한다: swift scripts/make-icon.swift build/AppIcon.iconset
// 그다음 iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset"
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(pixels) / 1024

    // macOS 아이콘 격자: 1024 캔버스 안 824 정사각, 모서리 반경 약 185
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824).applying(.init(scaleX: scale, y: scale))
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * scale, yRadius: 185 * scale)
    NSGradient(colors: [NSColor(red: 0.27, green: 0.30, blue: 0.85, alpha: 1),
                        NSColor(red: 0.10, green: 0.68, blue: 0.70, alpha: 1)])!
        .draw(in: shape, angle: -60)

    let config = NSImage.SymbolConfiguration(pointSize: 470 * scale, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let size = symbol.size
        symbol.draw(in: NSRect(x: (CGFloat(pixels) - size.width) / 2, y: (CGFloat(pixels) - size.height) / 2,
                               width: size.width, height: size.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    try render(points).write(to: URL(fileURLWithPath: "\(out)/icon_\(points)x\(points).png"))
    try render(points * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(points)x\(points)@2x.png"))
}
print(out)
