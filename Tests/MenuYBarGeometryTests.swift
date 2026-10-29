import CoreGraphics

@main struct MenuYBarGeometryTests {
    static func main() {
        var cases = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label); cases += 1
        }
        let exact = MenuYBarGeometry.flowPlan(itemWidths: [100, 100], availableWidth: 200, rowHeight: 33, spacing: 0)
        check(exact.rowCount == 1, "exact fit is one row")
        check(exact.positions == [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)], "native left-to-right placement")
        let wrapped = MenuYBarGeometry.flowPlan(itemWidths: [100, 100], availableWidth: 200, rowHeight: 33, spacing: 6)
        check(wrapped.rowCount == 2 && wrapped.positions[1] == CGPoint(x: 0, y: 33), "spacing correctly causes wrap")
        let capped = MenuYBarGeometry.flowPlan(itemWidths: [500, 30], availableWidth: 200, rowHeight: 33, spacing: 6)
        check(capped.widths[0] == 200 && capped.positions[1].y == 33, "very wide original item stays in viewport")
        check(MenuYBarGeometry.iconWidth(imageSize: CGSize(width: 138, height: 24), iconSize: 24) == 150, "clock keeps native aspect")
        check(MenuYBarGeometry.iconWidth(imageSize: CGSize(width: 1000, height: 24), iconSize: 24) == 312, "wide source is scaled to bounded width")
        check(MenuYBarGeometry.iconWidth(imageSize: CGSize(width: 1000, height: 24), iconSize: 24, maximumWidth: 180) == 180, "narrow display cap")
        check(MenuYBarGeometry.iconWidth(imageSize: CGSize(width: 0, height: 0), iconSize: 24) == 36, "missing image has square fallback")
        check(MenuYBarGeometry.rowHeight(iconSize: 24) == 33 && MenuYBarGeometry.rowHeight(iconSize: 24, compact: true) == 30, "native and compact cadence")
        let screens = [CGRect(x: 0, y: 0, width: 1728, height: 1117),
                       CGRect(x: -1920, y: -200, width: 1920, height: 1080),
                       CGRect(x: 1728, y: 300, width: 1280, height: 800),
                       CGRect(x: 0, y: 0, width: 640, height: 480)]
        for screen in screens {
            for iconSize in [16.0, 24.0, 36.0] {
                for count in [0, 1, 32, 47, 1000] {
                    for compact in [false, true] {
                        let widths = (0..<count).map { index in
                            MenuYBarGeometry.iconWidth(imageSize: CGSize(width: index % 11 == 0 ? 138 : 42, height: 24),
                                iconSize: iconSize, maximumWidth: screen.width - 28)
                        }
                        let visible = CGRect(x: screen.minX, y: screen.minY + 70, width: screen.width, height: screen.height - 103)
                        let frame = MenuYBarGeometry.shelfFrame(screen: screen, visible: visible, menuBarHeight: 33,
                            itemWidths: widths, iconSize: iconSize, compact: compact)
                        let plan = MenuYBarGeometry.flowPlan(itemWidths: widths, availableWidth: screen.width - 28,
                            rowHeight: MenuYBarGeometry.rowHeight(iconSize: iconSize, compact: compact), spacing: compact ? 3 : 6)
                        check(frame.minX == screen.minX && frame.width == screen.width, "full width on every display origin")
                        check(frame.maxY == screen.maxY - 33 && frame.minY >= visible.minY, "below native bar and above Dock")
                        check(frame.height <= MenuYBarGeometry.headerHeight + MenuYBarGeometry.dividerHeight + plan.size.height,
                              "window and flow share height calculation")
                        for i in plan.positions.indices {
                            check(plan.positions[i].x >= 0 && plan.positions[i].x + plan.widths[i] <= screen.width - 28 + 0.001,
                                  "every original icon has an accessible full row position")
                            check(plan.positions[i].y + MenuYBarGeometry.rowHeight(iconSize: iconSize, compact: compact) <= plan.size.height,
                                  "last item included in scrolling content")
                        }
                    }
                }
            }
        }
        print("PASS: \(cases) horizontal shelf geometry assertions (all-item placement, native sizing, overflow, Dock, display origins)")
    }
}
