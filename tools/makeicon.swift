import AppKit

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

func render(size: Int, to path: String) {
    let side = CGFloat(size)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: size,
                                     pixelsHigh: size,
                                     bitsPerSample: 8,
                                     samplesPerPixel: 4,
                                     hasAlpha: true,
                                     isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0,
                                     bitsPerPixel: 0) else { return }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: side, height: side).fill()

    let pad = side * 0.075
    let body = NSRect(x: pad, y: pad, width: side - pad * 2, height: side - pad * 2)
    let radius = (side - pad * 2) * 0.235
    let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 1.00, green: 0.38, blue: 0.22, alpha: 1.0),
        NSColor(srgbRed: 0.88, green: 0.06, blue: 0.18, alpha: 1.0)
    ])
    gradient?.draw(in: shape, angle: -90)

    // 顶部高光
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    let glow = NSGradient(colors: [
        NSColor(white: 1.0, alpha: 0.22),
        NSColor(white: 1.0, alpha: 0.0)
    ])
    glow?.draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: 90)
    NSGraphicsContext.restoreGraphicsState()

    // 播放三角
    let cx = side * 0.535
    let cy = side * 0.5
    let r = side * 0.185
    let triangle = NSBezierPath()
    triangle.move(to: NSPoint(x: cx - r * 0.62, y: cy + r))
    triangle.line(to: NSPoint(x: cx - r * 0.62, y: cy - r))
    triangle.line(to: NSPoint(x: cx + r * 0.82, y: cy))
    triangle.close()
    NSColor.white.setFill()
    triangle.fill()

    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: path))
}

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write("usage: makeicon <iconset-dir>\n".data(using: .utf8)!)
    exit(1)
}

let directory = arguments[1]
for (name, size) in sizes {
    render(size: size, to: "\(directory)/\(name)")
}
