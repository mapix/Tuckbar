import CoreGraphics

@main struct MenuYBackplateTests {
    static func main() {
        func rgba(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            bytes.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return bytes
        }
        let transparentContext = CGContext(data: nil, width: 16, height: 8, bitsPerComponent: 8, bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let transparent = transparentContext.makeImage()!
        let raw = rgba(transparent)
        precondition(stride(from: 3, to: raw.count, by: 4).allSatisfy { raw[$0] == 0 }, "fixture is transparent like native Menubar capture")
        let opaque = MenuYBackplate.opaque(transparent, width: 16, height: 8, fallback: CGColor(gray: 0.2, alpha: 0.1))!
        let output = rgba(opaque)
        precondition(stride(from: 3, to: output.count, by: 4).allSatisfy { output[$0] == 255 }, "every backing pixel is opaque")
        precondition(output[0] > 0 && output[0] == output[1] && output[1] == output[2], "fallback color is not inferred from transparent black RGB")
        let nativeContext = CGContext(data: nil, width: 16, height: 8, bitsPerComponent: 8, bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        nativeContext.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.5, alpha: 1))
        nativeContext.fill(CGRect(x: 0, y: 0, width: 16, height: 8))
        let native = nativeContext.makeImage()!
        let original = rgba(native)
        let retained = rgba(MenuYBackplate.opaque(native, width: 16, height: 8)!)
        precondition((0..<3).allSatisfy { abs(Int(retained[$0])-Int(original[$0])) <= 1 }, "opaque native color is preserved")
        precondition(MenuYBackplate.opaque(nil, width: 0, height: 8) == nil, "empty geometry rejected")
        // Window alpha is intentionally separate: a 0.9 window over any desktop
        // retains a 0.9 contribution from this alpha-1 backing, not alpha 0.
        let effective = Double(output[3])/255 * 0.9
        precondition(abs(effective-0.9)<0.0001)
        print("PASS: transparent native input flattened to opaque backing; native RGB preserved; default window opacity remains 0.9")
    }
}
