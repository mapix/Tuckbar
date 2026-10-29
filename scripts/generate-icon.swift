import AppKit
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let entries = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]
for (base, scale) in entries {
    let n = base * scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    let w = CGFloat(n)
    let background = NSBezierPath(roundedRect: CGRect(x: w*0.08, y: w*0.08, width: w*0.84, height: w*0.84),
                                 xRadius: w*0.18, yRadius: w*0.18)
    let gradient = NSGradient(starting: NSColor(calibratedRed: 0.08, green: 0.55, blue: 0.55, alpha: 1),
                              ending: NSColor(calibratedRed: 0.025, green: 0.22, blue: 0.29, alpha: 1))!
    gradient.draw(in: background, angle: -70)
    if let symbol = NSImage(systemSymbolName: "tray.full.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: w*0.5, weight: .medium)) {
        let image = NSImage(size: symbol.size, flipped: false) { bounds in
            symbol.draw(in: bounds)
            NSColor.white.setFill(); bounds.fill(using: .sourceIn)
            return true
        }
        let ratio = image.size.width / image.size.height
        let size = CGSize(width: w*0.54, height: w*0.54/ratio)
        image.draw(in: CGRect(x:(w-size.width)/2,y:(w-size.height)/2,width:size.width,height:size.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
    try rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name))
}
