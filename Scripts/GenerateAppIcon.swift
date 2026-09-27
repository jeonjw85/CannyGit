import AppKit

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift Scripts/GenerateAppIcon.swift <AppIcon.appiconset>")
}
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    let side = CGFloat(pixels)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: side, height: side)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let rect = NSRect(x: side * 0.07, y: side * 0.07, width: side * 0.86, height: side * 0.86)
    let tile = NSBezierPath(roundedRect: rect, xRadius: side * 0.19, yRadius: side * 0.19)
    tile.addClip()
    NSGradient(starting: NSColor(srgbRed: 0.09, green: 0.34, blue: 0.87, alpha: 1),
               ending: NSColor(srgbRed: 0.08, green: 0.72, blue: 0.63, alpha: 1))!.draw(in: rect, angle: 45)
    let path = NSBezierPath()
    path.lineWidth = max(1.5, side * 0.057)
    path.lineCapStyle = .round
    path.move(to: NSPoint(x: side * 0.34, y: side * 0.26))
    path.line(to: NSPoint(x: side * 0.34, y: side * 0.74))
    path.move(to: NSPoint(x: side * 0.34, y: side * 0.35))
    path.curve(to: NSPoint(x: side * 0.69, y: side * 0.64),
               controlPoint1: NSPoint(x: side * 0.34, y: side * 0.61),
               controlPoint2: NSPoint(x: side * 0.69, y: side * 0.37))
    NSColor.white.setStroke()
    path.stroke()
    for (x, y) in [(0.34, 0.26), (0.34, 0.74), (0.69, 0.64)] {
        let radius = side * 0.066
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: side * x - radius, y: side * y - radius,
                                   width: radius * 2, height: radius * 2)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using: .png, properties: [:])!
    try data.write(to: destination.appendingPathComponent("icon-\(pixels).png"), options: .atomic)
}
