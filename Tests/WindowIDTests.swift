import CoreGraphics
@main struct WindowIDTests {
    static func main() {
        for value in [Int.min, -9999, -1, 0, Int(UInt32.max) + 1, Int.max] {
            precondition(CGWindowID(safeWindowNumber: value) == nil)
        }
        for value in [1, 123, Int(UInt32.max)] {
            precondition(CGWindowID(safeWindowNumber: value) == UInt32(value))
        }
        print("PASS: negative remote proxy and out-of-range window IDs rejected; valid CG IDs preserved")
    }
}
