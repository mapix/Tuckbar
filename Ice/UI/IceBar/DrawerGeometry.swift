import Foundation
import CoreGraphics

/// AppKit screen coordinates. The drawer is always below the menu bar and
/// inside the usable display, including displays with negative origins.
enum DrawerGeometry {
    static func frame(screen: CGRect, visible: CGRect, anchorX: CGFloat,
                      menuBarHeight: CGFloat, itemCount: Int) -> CGRect {
        let margin: CGFloat = 8
        let width = min(352, max(1, screen.width - margin * 2))
        let top = screen.maxY - max(menuBarHeight, 24) - margin
        let availableHeight = max(1, top - max(screen.minY, visible.minY) - margin)
        let height = min(availableHeight, min(600, 172 + CGFloat(max(1, itemCount)) * 44))
        let x = min(max(anchorX - width + 28, screen.minX + margin), screen.maxX - width - margin)
        return CGRect(x: x, y: top - height, width: width, height: height)
    }
}
