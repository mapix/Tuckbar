import Foundation
import CoreGraphics

/// State for entry-hover presentation. A fresh entry edge is required to open;
/// merely activating the app, retaining a former pointer, or ticking a timer is
/// never an opening signal.
struct MenuYHoverPolicy {
    enum Action: Equatable { case none, show, hide }
    var enterDelay: TimeInterval
    var leaveDelay: TimeInterval
    private(set) var entryInside = false
    private(set) var showAt: TimeInterval?
    private(set) var hideAt: TimeInterval?
    private var lastPresented = false
    private var blockedUntilExit = false

    init(enterDelay: TimeInterval = 0.15, leaveDelay: TimeInterval = 0.2) {
        self.enterDelay = max(0, enterDelay)
        self.leaveDelay = max(0, leaveDelay)
    }

    mutating func update(entryInside newEntry: Bool, shelfInside: Bool,
                         visible: Bool, opening: Bool, busy: Bool,
                         now: TimeInterval, keepOpen: Bool = false) -> Action {
        guard now.isFinite else { return .none }
        let presented = visible || opening
        if lastPresented && !presented {
            // An explicit close while the pointer is still on the entry must
            // remain closed until it leaves and enters again.
            blockedUntilExit = entryInside && newEntry
            showAt = nil; hideAt = nil
        }
        let entered = !entryInside && newEntry
        if !newEntry { blockedUntilExit = false }
        entryInside = newEntry
        lastPresented = presented
        if entered && !presented && !blockedUntilExit { showAt = now + enterDelay }

        if entryInside || shelfInside {
            hideAt = nil
        } else {
            showAt = nil
            if presented && !keepOpen { hideAt = hideAt ?? now + leaveDelay }
            else { hideAt = nil }
        }
        if keepOpen { hideAt = nil }

        // An original-menu operation may be using synthetic mouse input. Do
        // not open/close its presentation midway; revisit after it settles.
        if busy {
            if let value = showAt, value <= now { showAt = now + 0.1 }
            if let value = hideAt, value <= now { hideAt = now + 0.1 }
            return .none
        }
        if let value = hideAt, value <= now, presented,
           !entryInside && !shelfInside && !keepOpen {
            hideAt = nil; showAt = nil
            return .hide
        }
        if let value = showAt, value <= now, !presented,
           entryInside && !blockedUntilExit {
            showAt = nil
            return .show
        }
        return .none
    }

    var nextDeadline: TimeInterval? {
        [showAt, hideAt].compactMap { $0 }.min()
    }

    mutating func primeEntry(_ inside: Bool) {
        entryInside = inside; showAt = nil; hideAt = nil; blockedUntilExit = false
    }

    mutating func resetEntry() {
        entryInside = false; showAt = nil; hideAt = nil
        blockedUntilExit = false
    }

    static func contains(_ point: CGPoint?, in frames: [CGRect]) -> Bool {
        guard let point, point.x.isFinite, point.y.isFinite else { return false }
        return frames.contains { $0.width > 0 && $0.height > 0 && $0.contains(point) }
    }

    /// Quartz has a top-left origin at the primary display, unlike AppKit's
    /// bottom-left origin. Negative/secondary-display x coordinates are retained.
    static func appKitPoint(quartz point: CGPoint, primaryTop: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryTop - point.y)
    }
}
