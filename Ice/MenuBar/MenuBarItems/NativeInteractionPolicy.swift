// Pure bounds/family rules used by the native event bridge.
import Foundation
import CoreGraphics

enum NativeInteractionPolicy {
    static let transientModifierMask: UInt = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20)

    static func hasTransientModifiers(_ flags: UInt) -> Bool {
        flags & transientModifierMask != 0
    }

    static func isClickable(frame: CGRect, isOnScreen: Bool, display: CGRect, minimumX: CGFloat) -> Bool {
        isOnScreen && frame.width > 0 && frame.height > 0 &&
        frame.minX >= minimumX - 0.5 && frame.maxX <= display.maxX + 2 &&
        frame.midY >= display.minY && frame.midY <= display.minY + 64
    }

    /// A temporary reveal only needs the eventual click point to be safe.
    /// This does not change the adjacency contract of permanent moves.
    static func isClickCenterSafe(frame: CGRect, isOnScreen: Bool, display: CGRect, minimumX: CGFloat) -> Bool {
        let center=CGPoint(x:frame.midX,y:frame.midY)
        return isOnScreen && frame.width>0 && frame.height>0 && display.contains(center) &&
            center.x>=minimumX+1 && center.y>=display.minY && center.y<=display.minY+64
    }

    /// A real menu is retained until it closes, even when its utility process
    /// is accessory/inactive. Opening a normal app window must not strand an icon.
    static func retainsTemporaryItem(layer: Int, frame: CGRect, popupLayer: Int, menuBand: CGRect) -> Bool {
        guard frame.width > 1, frame.height > 1 else { return false }
        if layer == popupLayer { return true }
        let beginsBelowMenu = frame.minY >= menuBand.maxY - 1 && frame.height > 8
        let largeTopPanel = frame.minY >= menuBand.minY - 1 && frame.height > 64
        return layer > 0 && frame.width <= 1200 && (beginsBelowMenu || largeTopPanel) &&
            frame.minY <= menuBand.maxY + 80
    }

    static func displayIndex(frame: CGRect, displays: [CGRect], preferredIndex: Int? = nil) -> Int? {
        let bands = displays.indices.filter { abs(displays[$0].minY-frame.minY)<2 }
        guard !bands.isEmpty else { return preferredIndex.flatMap { displays.indices.contains($0) ? $0 : nil } }
        let intersecting = bands.filter { min(frame.maxX,displays[$0].maxX)>max(frame.minX,displays[$0].minX) }
        if let best = intersecting.max(by: {
            min(frame.maxX,displays[$0].maxX)-max(frame.minX,displays[$0].minX) <
            min(frame.maxX,displays[$1].maxX)-max(frame.minX,displays[$1].minX)
        }) { return best }
        if let preferredIndex, bands.contains(preferredIndex) { return preferredIndex }
        return bands.min { left,right in
            let l = max(displays[left].minX-frame.midX,frame.midX-displays[left].maxX,0)
            let r = max(displays[right].minX-frame.midX,frame.midX-displays[right].maxX,0)
            return l<r
        }
    }

    static func outerApplicationPath(_ url: URL?) -> String? {
        guard let parts = url?.standardizedFileURL.pathComponents,
              let end = parts.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return NSString.path(withComponents: Array(parts[...end]))
    }

    static func sameApplicationFamily(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let a = outerApplicationPath(lhs), let b = outerApplicationPath(rhs) else { return false }
        return a == b
    }
}
