import Foundation
import CoreGraphics
@main struct GeometryTests {
    static func main() {
        var count = 0
        let screens = [CGRect(x: 0, y: 0, width: 1512, height: 982),
                       CGRect(x: -1920, y: -200, width: 1920, height: 1080),
                       CGRect(x: 1512, y: 300, width: 1280, height: 800),
                       CGRect(x: 0, y: 0, width: 800, height: 600)]
        for screen in screens {
            for dock in [0.0, 80.0] {
                let visible = CGRect(x: screen.minX, y: screen.minY + dock,
                                     width: screen.width, height: screen.height - dock - 38)
                for items in [0, 1, 8, 32, 100, 1000] {
                    for anchor in [screen.minX, screen.midX, screen.maxX - 50, screen.maxX] {
                        for bar in [24.0, 38.0] {
                            let frame = DrawerGeometry.frame(screen: screen, visible: visible,
                                anchorX: anchor, menuBarHeight: bar, itemCount: items)
                            precondition(frame.minX >= screen.minX && frame.maxX <= screen.maxX)
                            precondition(frame.minY >= visible.minY && frame.maxY <= screen.maxY - bar)
                            precondition(frame.width <= 352 && frame.height <= 600)
                            precondition(frame.width > 0 && frame.height > 0)
                            count += 1
                        }
                    }
                }
            }
        }
        print("PASS: \(count) drawer geometry cases (notch, long lists, dock, multiple display origins)")
    }
}
