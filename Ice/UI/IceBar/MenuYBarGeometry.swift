import CoreGraphics

/// Shared sizing for the SwiftUI flow and its AppKit window. Coordinates are
/// AppKit screen coordinates; no display origin is assumed to be zero.
enum MenuYBarGeometry {
    static let horizontalPadding: CGFloat = 14
    static let headerHeight: CGFloat = 33
    static let dividerHeight: CGFloat = 0.5
    static let iconHorizontalPadding: CGFloat = 12

    struct FlowPlan {
        let positions: [CGPoint]
        let widths: [CGFloat]
        let rowCount: Int
        let size: CGSize
    }

    static func iconWidth(imageSize: CGSize?, iconSize: CGFloat, maximumWidth: CGFloat = .greatestFiniteMagnitude) -> CGFloat {
        let height = finitePositive(iconSize, fallback: 24)
        let ratio: CGFloat
        if let imageSize, imageSize.width.isFinite, imageSize.height.isFinite,
           imageSize.width > 0, imageSize.height > 0 {
            ratio = imageSize.width / imageSize.height
        } else { ratio = 1 }
        let content = min(300, max(height, ratio * height))
        return min(finitePositive(maximumWidth, fallback: content + iconHorizontalPadding), content + iconHorizontalPadding)
    }

    static func rowHeight(iconSize: CGFloat, compact: Bool = false) -> CGFloat {
        let size = finitePositive(iconSize, fallback: 24)
        return compact ? max(30, size + 6) : max(33, size + 9)
    }

    static func flowPlan(itemWidths: [CGFloat], availableWidth: CGFloat, rowHeight: CGFloat, spacing: CGFloat) -> FlowPlan {
        let available = finitePositive(availableWidth, fallback: 1)
        let height = finitePositive(rowHeight, fallback: 33)
        let gap = spacing.isFinite ? max(0, spacing) : 0
        var positions = [CGPoint](), widths = [CGFloat]()
        var x: CGFloat = 0, row = 0
        for requested in itemWidths {
            let width = min(available, finitePositive(requested, fallback: 1))
            if x > 0 && x + width > available + 0.001 { row += 1; x = 0 }
            positions.append(CGPoint(x: x, y: CGFloat(row) * height))
            widths.append(width)
            x += width + gap
        }
        let rows = max(1, row + 1)
        return FlowPlan(positions: positions, widths: widths, rowCount: rows,
                        size: CGSize(width: available, height: CGFloat(rows) * height))
    }

    static func shelfFrame(screen: CGRect, visible: CGRect, menuBarHeight: CGFloat,
                           itemWidths: [CGFloat], iconSize: CGFloat, compact: Bool = false,
                           footerHeight: CGFloat = 0) -> CGRect {
        let thickness = min(screen.height, finitePositive(menuBarHeight, fallback: 33))
        let top = screen.maxY - thickness
        let bottom = max(screen.minY, visible.minY) + min(8, max(0, top - screen.minY))
        let available = max(1, top - bottom)
        let plan = flowPlan(itemWidths: itemWidths,
                            availableWidth: max(1, screen.width - horizontalPadding * 2),
                            rowHeight: rowHeight(iconSize: iconSize, compact: compact),
                            spacing: compact ? 3 : 6)
        let footer = footerHeight.isFinite ? max(0, footerHeight) : 0
        let height = min(available, headerHeight + dividerHeight + plan.size.height + footer)
        return CGRect(x: screen.minX, y: top - height, width: screen.width, height: height)
    }

    private static func finitePositive(_ value: CGFloat, fallback: CGFloat) -> CGFloat {
        value.isFinite && value > 0 ? value : fallback
    }
}
