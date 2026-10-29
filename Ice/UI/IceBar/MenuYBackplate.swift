import CoreGraphics

/// Native background captures can contain transparent pixels. Flattening onto
/// an opaque backing keeps window opacity (a separate setting) predictable.
enum MenuYBackplate {
    static func opaque(_ image: CGImage?, width: Int, height: Int,
                       fallback: CGColor = CGColor(gray: 0.08, alpha: 1)) -> CGImage? {
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(fallback.copy(alpha: 1) ?? CGColor(gray: 0.08, alpha: 1))
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.fill(rect)
        if let image { context.draw(image, in: rect) }
        return context.makeImage()
    }
}
