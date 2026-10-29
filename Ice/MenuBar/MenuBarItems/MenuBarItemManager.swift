//
//  MenuBarItemManager.swift
//  Ice
//

import Cocoa
import Combine

/// Manager for menu bar items.
@MainActor
final class MenuBarItemManager: ObservableObject {
    /// Cache for menu bar items.
    struct ItemCache: Hashable {
        /// All cached menu bar items, keyed by section.
        private var items = [MenuBarSection.Name: [MenuBarItem]]()

        /// All cached menu bar items.
        var allItems: [MenuBarItem] {
            MenuBarSection.Name.allCases.reduce(into: []) { result, section in
                result.append(contentsOf: self[section])
            }
        }

        /// The cached menu bar items managed by Ice.
        var managedItems: [MenuBarItem] {
            MenuBarSection.Name.allCases.reduce(into: []) { result, section in
                result.append(contentsOf: managedItems(for: section))
            }
        }

        /// Clears the cache.
        mutating func clear() {
            items.removeAll()
        }

        /// Returns the cached menu bar items managed by Ice for the given section.
        func managedItems(for section: MenuBarSection.Name) -> [MenuBarItem] {
            self[section].filter { item in
                // Filter out items that can't be hidden.
                guard item.canBeHidden else {
                    return false
                }

                if item.owningApplication == .current {
                    // Ice icon is the only item owned by Ice that should be included.
                    guard item.title == ControlItem.Identifier.iceIcon.rawValue else {
                        return false
                    }
                }

                return true
            }
        }

        /// Returns the name of the section for the given menu bar item.
        func section(for item: MenuBarItem) -> MenuBarSection.Name? {
            for (section, items) in self.items where items.contains(where: { $0.windowID == item.windowID }) {
                return section
            }
            return nil
        }

        /// Returns the name of the section containing the item with the given window.
        func section(forWindowID windowID: CGWindowID) -> MenuBarSection.Name? {
            for (section, items) in self.items where items.contains(where: { $0.windowID == windowID }) {
                return section
            }
            return nil
        }

        /// Accesses the items in the given section.
        subscript(section: MenuBarSection.Name) -> [MenuBarItem] {
            get { items[section, default: []] }
            set { items[section] = newValue }
        }
    }

    /// Context for a temporarily shown menu bar item.
    private struct TempShownItemContext {
        let windowID: CGWindowID
        let info: MenuBarItemInfo
        let returnDestination: MoveDestination
        let returnSection: MenuBarSection.Name
        let sourcePID: pid_t?
        let menuBand: CGRect
        var shownInterfaceWindows = [WindowInfo]()
        var originalOnScreenWindowIDs = Set<CGWindowID>()
        var movementCheckpointID: UUID? = nil
        var movementRollbackRequested = false
        var originalFrame: CGRect? = nil
        var originalWindowOrder = [CGWindowID]()
        var originalOnScreen: Bool? = nil

        var isShowingInterface: Bool {
            shownInterfaceWindows.contains { observed in
                guard let window = WindowInfo(windowID: observed.windowID), window.isOnScreen else { return false }
                return NativeInteractionPolicy.retainsTemporaryItem(layer: window.layer, frame: window.frame,
                    popupLayer: Int(CGWindowLevelForKey(.popUpMenuWindow)), menuBand: menuBand)
            }
        }
    }

    /// The manager's menu bar item cache.
    @Published private(set) var itemCache = ItemCache()

    /// The shared app state.
    private(set) weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// Cached window identifiers for the most recent items.
    private var cachedItemWindowIDs = [CGWindowID]()

    /// Context values for the current temporarily shown items.
    private var tempShownItemContexts = [TempShownItemContext]()

    /// A timer that determines when to rehide the temporarily shown items.
    private var tempShownItemsTimer: Timer?

    /// The last time a menu bar item was moved.
    private var lastItemMoveStartDate: Date?

    /// The last time the mouse was moved.
    private var lastMouseMoveStartDate: Date?

    /// Counter to determine if a menu bar item, or group of menu bar
    /// items is being moved.
    private var itemMoveCount = 0
    private var isOpeningInterface = false
    private nonisolated let nativeLifecycle = NativeInteractionLifecycle()
    private var activeNativeWorkCount = 0
    private var terminationTask: Task<NativeRestorationReport,Never>?
    private struct PendingSyntheticPress { let id: UUID; let release: CGEvent; let ownerPID: pid_t }
    private var pendingSyntheticPress: PendingSyntheticPress?
    private var cursorLeases = [(id: UUID, point: CGPoint?)]()
    var isPreparingForTermination: Bool { nativeLifecycle.isStopping }
    var isShuttingDown: Bool { nativeLifecycle.isStopping }
    var pendingRestorationWindowIDs: [CGWindowID] { tempShownItemContexts.map(\.windowID) }
    struct NativeMovementCheckpoint { let id: UUID; let windowID: CGWindowID }

    struct NativeRestorationReport {
        let restoredCount: Int
        let remainingWindowIDs: [CGWindowID]
        let elapsed: TimeInterval
        var completed: Bool { remainingWindowIDs.isEmpty }
    }

    /// A Boolean value that indicates whether a mouse button is down.
    private var isMouseButtonDown = false

    /// Event type mask for tracking mouse events.
    private let mouseTrackingMask: NSEvent.EventTypeMask = [
        .mouseMoved,
        .leftMouseDown,
        .rightMouseDown,
        .otherMouseDown,
        .leftMouseUp,
        .rightMouseUp,
        .otherMouseUp,
    ]

    /// A Boolean value that indicates whether a menu bar item, or
    /// group of menu bar items is being moved.
    var isMovingItem: Bool {
        itemMoveCount > 0
    }

    /// A Boolean value that indicates whether a menu bar item has
    /// recently moved.
    var itemHasRecentlyMoved: Bool {
        guard let lastItemMoveStartDate else {
            return false
        }
        return Date.now.timeIntervalSince(lastItemMoveStartDate) <= 1
    }

    /// A Boolean value that indicates whether the mouse has recently moved.
    var mouseHasRecentlyMoved: Bool {
        guard let lastMouseMoveStartDate else {
            return false
        }
        return Date.now.timeIntervalSince(lastMouseMoveStartDate) <= 1
    }

    private func beginCursorLease(returnTo point: CGPoint?) -> UUID {
        let id = UUID(); cursorLeases.append((id:id,point:point)); MouseCursor.hide(); return id
    }
    private func endCursorLease(_ id: UUID) {
        guard let index = cursorLeases.firstIndex(where:{ $0.id == id }) else { return }
        let lease = cursorLeases.remove(at:index)
        if let point = lease.point { MouseCursor.warp(to:point) }
        MouseCursor.show()
    }
    private func releaseCursorLeases() {
        let leases = cursorLeases; cursorLeases.removeAll()
        if let point = leases.first(where:{ $0.point != nil })?.point { MouseCursor.warp(to:point) }
        for _ in leases { MouseCursor.show() }
    }
    private func armSyntheticPress(down: CGEvent, release: CGEvent, item: MenuBarItem,
                                   alternateRelease: CGEvent? = nil) -> UUID {
        releaseSyntheticPress()
        let id = UUID(); pendingSyntheticPress = PendingSyntheticPress(id:id,release:release,ownerPID:item.ownerPID)
        var upTags = [release.getIntegerValueField(.eventSourceUserData)]
        if let alternateRelease { upTags.append(alternateRelease.getIntegerValueField(.eventSourceUserData)) }
        nativeLifecycle.armPress(downTag:down.getIntegerValueField(.eventSourceUserData),upTags:upTags)
        return id
    }
    private func finishSyntheticPress(_ id: UUID) {
        guard pendingSyntheticPress?.id == id else { return }
        releaseSyntheticPress(id)
    }
    private func releaseSyntheticPress(_ id: UUID? = nil) {
        guard let press = pendingSyntheticPress, id == nil || press.id == id else { return }
        pendingSyntheticPress = nil
        let plan = nativeLifecycle.takeReleasePlan()
        // Balance each delivery leg exactly once. A session echo can be received
        // before the owner leg runs; never mistake that for a completed drag.
        if plan.session { postEvent(press.release,to:.sessionEventTap) }
        if plan.owner { postEvent(press.release,to:.pid(press.ownerPID)) }
    }

    /// Creates a manager with the given app state.
    init(appState: AppState) {
        self.appState = appState
    }

    /// Sets up the manager.
    func performSetup() {
        configureCancellables()
    }

    /// Configures the internal observers for the manager.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        Timer.publish(every: 5, on: .main, in: .default)
            .autoconnect()
            .merge(with: Just(.now))
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                Task {
                    await self.cacheItemsIfNeeded()
                }
            }
            .store(in: &c)

        NSWorkspace.shared.publisher(for: \.runningApplications)
            .delay(for: 0.25, scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                Task {
                    await self.cacheItemsIfNeeded()
                }
            }
            .store(in: &c)

        // No RunLoopLocalEventMonitor here: its dequeue-and-repost of ALL
        // pending events during the eventTracking runloop mode breaks SwiftUI
        // Button clicks app-wide on macOS 26 (hover works, clicks never
        // complete — user-verified 2026-07-05). The global half of
        // UniversalEventMonitor still observes menu bar drags, which happen in
        // other processes; the only loss is mouse-state tracking during drags
        // inside Barkeep's own windows.
        UniversalEventMonitor.publisher(for: mouseTrackingMask)
        .removeDuplicates()
        .sink { [weak self] event in
            guard let self else {
                return
            }
            switch event.type {
            case .mouseMoved:
                lastMouseMoveStartDate = .now
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                isMouseButtonDown = true
            case .leftMouseUp, .rightMouseUp, .otherMouseUp:
                isMouseButtonDown = false
            default:
                break
            }
        }
        .store(in: &c)

        cancellables = c
    }
}

// MARK: - Cache Items

extension MenuBarItemManager {
    /// Logs a warning that the given menu bar item was not added to the cache.
    private func logNotCachedWarning(for item: MenuBarItem) {
        Logger.itemManager.warning("\(item.logString) was not cached")
    }

    /// Logs a reason for skipping the cache.
    private func logSkippingCache(reason: String) {
        Logger.itemManager.debug("Skipping menu bar item cache as \(reason)")
    }

    /// Caches the given menu bar items, without checking whether the control
    /// items are in the correct order.
    private func uncheckedCacheItems(
        hiddenControlItem: MenuBarItem,
        alwaysHiddenControlItem: MenuBarItem?,
        otherItems: [MenuBarItem]
    ) {
        Logger.itemManager.debug("Caching menu bar items")

        let predicates = Predicates.sectionPredicates(
            hiddenControlItem: hiddenControlItem,
            alwaysHiddenControlItem: alwaysHiddenControlItem
        )

        var cache = ItemCache()
        var tempShownItems = [(MenuBarItem, MoveDestination)]()

        for item in otherItems {
            if let context = tempShownItemContexts.first(where: { $0.windowID == item.windowID }) {
                // Keep track of temporarily shown items and their return destinations separately.
                // We want to cache them as if they were in their original locations. Once all other
                // items are cached, use the return destinations to insert the items into the cache
                // at the correct position.
                tempShownItems.append((item, context.returnDestination))
            } else if predicates.isInVisibleSection(item) {
                cache[.visible].append(item)
            } else if predicates.isInHiddenSection(item) {
                cache[.hidden].append(item)
            } else if predicates.isInAlwaysHiddenSection(item) {
                cache[.alwaysHidden].append(item)
            } else {
                logNotCachedWarning(for: item)
            }
        }

        for (item, destination) in tempShownItems {
            switch destination {
            case .leftOfItem(let targetItem):
                switch targetItem.info {
                case .hiddenControlItem:
                    cache[.hidden].append(item)
                case .alwaysHiddenControlItem:
                    cache[.alwaysHidden].append(item)
                default:
                    if
                        let section = cache.section(forWindowID: targetItem.windowID),
                        let index = cache[section].firstIndex(where: { $0.windowID == targetItem.windowID })
                    {
                        let clampedIndex = index.clamped(to: cache[section].startIndex...cache[section].endIndex)
                        cache[section].insert(item, at: clampedIndex)
                    }
                }
            case .rightOfItem(let targetItem):
                switch targetItem.info {
                case .hiddenControlItem:
                    cache[.visible].insert(item, at: 0)
                case .alwaysHiddenControlItem:
                    cache[.hidden].insert(item, at: 0)
                default:
                    if
                        let section = cache.section(forWindowID: targetItem.windowID),
                        let index = cache[section].firstIndex(where: { $0.windowID == targetItem.windowID })
                    {
                        let clampedIndex = (index - 1).clamped(to: cache[section].startIndex...cache[section].endIndex)
                        cache[section].insert(item, at: clampedIndex)
                    }
                }
            }
        }

        itemCache = cache
    }

    /// Caches the current menu bar items if needed, ensuring that the control
    /// items are in the correct order.
    func refreshItems() async {
        guard !nativeLifecycle.isStopping else { return }
        cachedItemWindowIDs = []
        await cacheItemsIfNeeded()
    }

    func cacheItemsIfNeeded() async {
        guard !nativeLifecycle.isStopping else { return }
        do {
            try await waitForItemsToStopMoving(timeout: .seconds(1))
        } catch is TaskTimeoutError {
            logSkippingCache(reason: "an item is currently being moved")
            return
        } catch {
            guard !itemHasRecentlyMoved else {
                logSkippingCache(reason: "an item was recently moved")
                return
            }
        }

        let itemWindowIDs = Bridging.getWindowList(option: [.menuBarItems, .activeSpace])
        if cachedItemWindowIDs == itemWindowIDs {
            logSkippingCache(reason: "item windows have not changed")
            return
        } else {
            cachedItemWindowIDs = itemWindowIDs
        }

        var items = MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true)

        let hiddenControlItem = items.firstIndex(matching: .hiddenControlItem).map { items.remove(at: $0) }
        let alwaysHiddenControlItem = items.firstIndex(matching: .alwaysHiddenControlItem).map { items.remove(at: $0) }

        guard let hiddenControlItem else {
            Logger.itemManager.warning("Missing control item for hidden section")
            Logger.itemManager.debug("Clearing menu bar item cache")
            itemCache.clear()
            return
        }

        do {
            if let alwaysHiddenControlItem {
                try await enforceControlItemOrder(
                    hiddenControlItem: hiddenControlItem,
                    alwaysHiddenControlItem: alwaysHiddenControlItem
                )
            }
            uncheckedCacheItems(
                hiddenControlItem: hiddenControlItem,
                alwaysHiddenControlItem: alwaysHiddenControlItem,
                otherItems: items
            )
            if let appState {
                LayoutDiagnostics.dump(label: "cache-rebuilt", appState: appState)
            }
        } catch {
            Logger.itemManager.error("Error enforcing control item order: \(error)")
            Logger.itemManager.debug("Clearing menu bar item cache")
            itemCache.clear()
        }
    }
}

// MARK: - Menu Bar Item Events -

extension MenuBarItemManager {
    /// An error that can occur during menu bar item event operations.
    struct EventError: Error, CustomStringConvertible, LocalizedError {
        /// Error codes within the domain of menu bar item event errors.
        enum ErrorCode: Int, CustomStringConvertible {
            /// An operation could not be completed.
            case couldNotComplete

            /// The creation of a menu bar item event failed.
            case eventCreationFailure

            /// The shared app state is invalid or could not be found.
            case invalidAppState

            /// An event source could not be created or is otherwise invalid.
            case invalidEventSource

            /// The location of the mouse cursor is invalid or could not be found.
            case invalidCursorLocation

            /// A menu bar item is invalid.
            case invalidItem

            /// A menu bar item cannot be moved.
            case notMovable

            /// A menu bar item event operation timed out.
            case eventOperationTimeout

            /// A menu bar item frame check timed out.
            case frameCheckTimeout

            /// An operation timed out.
            case otherTimeout

            /// Description of the code for debugging purposes.
            var description: String {
                switch self {
                case .couldNotComplete: "couldNotComplete"
                case .eventCreationFailure: "eventCreationFailure"
                case .invalidAppState: "invalidAppState"
                case .invalidEventSource: "invalidEventSource"
                case .invalidCursorLocation: "invalidCursorLocation"
                case .invalidItem: "invalidItem"
                case .notMovable: "notMovable"
                case .eventOperationTimeout: "eventOperationTimeout"
                case .frameCheckTimeout: "frameCheckTimeout"
                case .otherTimeout: "otherTimeout"
                }
            }

            /// A string to use for logging purposes.
            var logString: String {
                "\(self) (rawValue: \(rawValue))"
            }
        }

        /// The error code of this error.
        let code: ErrorCode

        /// The error's menu bar item.
        let item: MenuBarItem

        /// The message associated with this error.
        var message: String {
            switch code {
            case .couldNotComplete:
                "Could not complete event operation for \"\(item.displayName)\""
            case .eventCreationFailure:
                "Failed to create event for \"\(item.displayName)\""
            case .invalidAppState:
                "Invalid app state for \"\(item.displayName)\""
            case .invalidEventSource:
                "Invalid event source for \"\(item.displayName)\""
            case .invalidCursorLocation:
                "Invalid cursor location for \"\(item.displayName)\""
            case .invalidItem:
                "\"\(item.displayName)\" is invalid"
            case .notMovable:
                "\"\(item.displayName)\" is not movable"
            case .eventOperationTimeout:
                "Event operation timed out for \"\(item.displayName)\""
            case .frameCheckTimeout:
                "Frame check timed out for \"\(item.displayName)\""
            case .otherTimeout:
                "Operation timed out for \"\(item.displayName)\""
            }
        }

        /// Description of the error for debugging purposes.
        var description: String {
            var parameters = [String]()
            parameters.append("code: \(code.logString)")
            parameters.append("item: \(item.logString)")
            return "\(Self.self)(\(parameters.joined(separator: ", ")))"
        }

        /// Description of the error for display purposes.
        var errorDescription: String? {
            message
        }

        /// Suggestion for recovery from the error.
        var recoverySuggestion: String? {
            "Please try again. If the error persists, please file a bug report."
        }
    }
}

// MARK: - Async Waiters

extension MenuBarItemManager {
    /// Waits asynchronously for the given operation to complete.
    /// 
    /// - Parameters:
    ///   - timeout: Amount of time to wait before throwing an error.
    ///   - operation: The operation to perform.
    private func waitWithTask(timeout: Duration?, operation: @escaping @Sendable () async throws -> Void) async throws {
        let task = if let timeout {
            Task(timeout: timeout, operation: operation)
        } else {
            Task(operation: operation)
        }
        try await withTaskCancellationHandler(operation:{ try await task.value },onCancel:{ task.cancel() })
    }

    /// Waits asynchronously for all menu bar items to stop moving.
    ///
    /// - Parameter timeout: Amount of time to wait before throwing an error.
    func waitForItemsToStopMoving(timeout: Duration? = nil) async throws {
        try await waitWithTask(timeout: timeout) { [weak self] in
            guard let self else {
                return
            }
            while await isMovingItem {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    /// Waits asynchronously for the mouse to stop moving.
    ///
    /// - Parameters:
    ///   - threshold: A threshold to use to determine whether the mouse has stopped moving.
    ///   - timeout: Amount of time to wait before throwing an error.
    func waitForMouseToStopMoving(threshold: TimeInterval = 0.1, timeout: Duration? = nil) async throws {
        try await waitWithTask(timeout: timeout) { [weak self] in
            guard let self else {
                return
            }
            while true {
                try Task.checkCancellation()
                guard let date = await lastMouseMoveStartDate else {
                    break
                }
                if Date.now.timeIntervalSince(date) > threshold {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    /// Waits asynchronously until no modifier keys are pressed.
    ///
    /// - Parameter timeout: Amount of time to wait before throwing an error.
    func waitForNoModifiersPressed(timeout: Duration? = nil) async throws {
        try await waitWithTask(timeout: timeout) {
            // Polling is cancellation-safe. A continuation waiting for an event
            // cannot finish a TaskGroup timeout while a user still holds a key.
            while NativeInteractionPolicy.hasTransientModifiers(NSEvent.modifierFlags.rawValue) {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }
}

// MARK: - Move Items

extension MenuBarItemManager {
    /// A destination that a menu bar item can be moved to.
    enum MoveDestination {
        /// The menu bar item will be moved to the left of the given menu bar item.
        case leftOfItem(MenuBarItem)

        /// The menu bar item will be moved to the right of the given menu bar item.
        case rightOfItem(MenuBarItem)

        /// A string to use for logging purposes.
        var logString: String {
            switch self {
            case .leftOfItem(let item): "left of \(item.logString)"
            case .rightOfItem(let item): "right of \(item.logString)"
            }
        }
    }

    /// Returns the current frame for the given item.
    ///
    /// - Parameter item: The item to return the current frame for.
    private func getCurrentFrame(for item: MenuBarItem) -> CGRect? {
        guard let frame = Bridging.getWindowFrame(for: item.window.windowID) else {
            Logger.itemManager.error("Couldn't get current frame for \(item.logString)")
            return nil
        }
        return frame
    }

    /// Returns the end point for moving an item to the given destination.
    ///
    /// - Parameter destination: The destination to return the end point for.
    private func getEndPoint(for destination: MoveDestination) throws -> CGPoint {
        switch destination {
        case .leftOfItem(let targetItem):
            guard let currentFrame = getCurrentFrame(for: targetItem) else {
                throw EventError(code: .invalidItem, item: targetItem)
            }
            // On macOS 26 (Tahoe), a drop released at exactly the target's edge
            // is resolved to the WRONG side of the target (verified 2026-07-04:
            // release at minX landed the item adjacent on the right). Releasing
            // 1pt past the edge resolves to the intended side on both old and
            // new systems.
            return CGPoint(x: currentFrame.minX - 1, y: currentFrame.midY)
        case .rightOfItem(let targetItem):
            guard let currentFrame = getCurrentFrame(for: targetItem) else {
                throw EventError(code: .invalidItem, item: targetItem)
            }
            return CGPoint(x: currentFrame.maxX + 1, y: currentFrame.midY)
        }
    }

    /// Returns the fallback point for returning the given item to its original
    /// position if a move fails.
    ///
    /// - Parameter item: The item to return the fallback point for.
    private func getFallbackPoint(for item: MenuBarItem) throws -> CGPoint {
        guard let currentFrame = getCurrentFrame(for: item) else {
            throw EventError(code: .invalidItem, item: item)
        }
        return CGPoint(x: currentFrame.midX, y: currentFrame.midY)
    }

    /// Returns the target item for the given destination.
    ///
    /// - Parameter destination: The destination to get the target item from.
    private func getTargetItem(for destination: MoveDestination) -> MenuBarItem {
        switch destination {
        case .leftOfItem(let targetItem), .rightOfItem(let targetItem): targetItem
        }
    }

    /// Returns a Boolean value that indicates whether the given item is in the
    /// correct position for the given destination.
    ///
    /// - Parameters:
    ///   - item: The item to check the position of.
    ///   - destination: The destination to compare the item's position against.
    private func itemHasCorrectPosition(item: MenuBarItem, for destination: MoveDestination) throws -> Bool {
        guard let currentFrame = getCurrentFrame(for: item) else {
            throw EventError(code: .invalidItem, item: item)
        }
        switch destination {
        case .leftOfItem(let targetItem):
            guard let currentTargetFrame = getCurrentFrame(for: targetItem) else {
                throw EventError(code: .invalidItem, item: targetItem)
            }
            if abs(currentFrame.maxX - currentTargetFrame.minX) <= 0.5 {
                return true
            }
            // macOS may pin immovable items (e.g. BentoBox glued to Clock)
            // between the moved item and its target, making exact adjacency
            // unsatisfiable. Accept the position if everything in the gap
            // is immovable.
            return currentFrame.maxX < currentTargetFrame.minX && gapContainsOnlyImmovableItems(
                from: currentFrame.maxX, to: currentTargetFrame.minX
            )
        case .rightOfItem(let targetItem):
            guard let currentTargetFrame = getCurrentFrame(for: targetItem) else {
                throw EventError(code: .invalidItem, item: targetItem)
            }
            if abs(currentFrame.minX - currentTargetFrame.maxX) <= 0.5 {
                return true
            }
            return currentFrame.minX > currentTargetFrame.maxX && gapContainsOnlyImmovableItems(
                from: currentTargetFrame.maxX, to: currentFrame.minX
            )
        }
    }

    /// Returns whether the horizontal span between the given x positions is
    /// fully covered by immovable menu bar items (and nothing else).
    private func gapContainsOnlyImmovableItems(from minX: CGFloat, to maxX: CGFloat) -> Bool {
        guard maxX > minX else {
            return false
        }
        let items = MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true)
        let gapItems = items.filter { other in
            other.frame.minX >= minX && other.frame.maxX <= maxX
        }
        guard !gapItems.isEmpty else {
            return false
        }
        // The gap must be exactly tiled by immovable items.
        let coveredWidth = gapItems.reduce(0) { $0 + $1.frame.width }
        return gapItems.allSatisfy { !$0.isMovable || !$0.canBeHidden } && abs(coveredWidth - (maxX - minX)) < 0.5
    }

    /// Returns a Boolean value that indicates whether the given events have the
    /// same values for each integer value field.
    ///
    /// - Parameters:
    ///   - events: The events to compare.
    ///   - integerFields: An array of integer value fields to compare on each event.
    private nonisolated func eventsMatch(_ events: [CGEvent], by integerFields: [CGEventField]) -> Bool {
        var fieldValues = Set<[Int64]>()
        for event in events {
            let values = integerFields.map(event.getIntegerValueField)
            fieldValues.insert(values)
            if fieldValues.count != 1 {
                return false
            }
        }
        return true
    }

    /// Posts an event to the given event tap location.
    ///
    /// - Parameters:
    ///   - event: The event to post.
    ///   - location: The event tap location to post the event to.
    private nonisolated func postEvent(_ event: CGEvent, to location: EventTap.Location,
                                      token: NativeInteractionLifecycle.Token? = nil) {
        if let token, !nativeLifecycle.accepts(token) { return }
        let down = event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown
        let up = event.type == .leftMouseUp || event.type == .rightMouseUp || event.type == .otherMouseUp
        let toOwner: Bool
        if case .pid = location { toOwner=true } else { toOwner=false }
        nativeLifecycle.notePosted(tag:event.getIntegerValueField(.eventSourceUserData),isDown:down,isUp:up,toOwner:toOwner)
        Logger.itemManager.debug("Posting \(event.type.logString) to \(location.logString)")
        switch location {
        case .hidEventTap:
            event.post(tap: .cghidEventTap)
        case .sessionEventTap:
            event.post(tap: .cgSessionEventTap)
        case .annotatedSessionEventTap:
            event.post(tap: .cgAnnotatedSessionEventTap)
        case .pid(let pid):
            event.postToPid(pid)
        }
    }

    /// Posts an event to the given event tap location and waits until it is
    /// received before returning.
    ///
    /// - Parameters:
    ///   - event: The event to post.
    ///   - location: The event tap location to post the event to.
    ///   - item: The menu bar item that the event affects.
    private func postEventAndWaitToReceive(
        _ event: CGEvent,
        to location: EventTap.Location,
        item: MenuBarItem,
        token: NativeInteractionLifecycle.Token? = nil
    ) async throws {
        guard let token = token ?? nativeLifecycle.token(), nativeLifecycle.accepts(token) else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            let eventTap = EventTap(
                options: .listenOnly,
                location: location,
                place: .tailAppendEventTap,
                types: [event.type]
            ) { [weak self] proxy, type, rEvent in
                guard let self else {
                    proxy.disable()
                    return nil
                }

                // Reenable the tap if disabled by the system.
                if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
                    proxy.enable()
                    return nil
                }

                // Verify that the received event was the sent event.
                guard eventsMatch([rEvent, event], by: [.eventSourceUserData]) else {
                    return nil
                }

                if !nativeLifecycle.accepts(token) {
                    proxy.disable(); continuation.resume(throwing:CancellationError()); return nil
                }
                // Ensure the tap is enabled, preventing multiple calls to resume().
                guard proxy.isEnabled else {
                    Logger.itemManager.debug("Event tap \"\(proxy.label)\" is disabled (item: \(item.logString))")
                    return nil
                }

                Logger.itemManager.debug("Received \(type.logString) at \(location.logString) (item: \(item.logString))")

                // Disable the tap and resume the continuation.
                proxy.disable()
                continuation.resume()

                return nil
            }

            eventTap.enable(timeout: .milliseconds(250)) {
                Logger.itemManager.error("Event tap \"\(eventTap.label)\" timed out (item: \(item.logString))")
                eventTap.disable()
                continuation.resume(throwing: EventError(code: .eventOperationTimeout, item: item))
            }

            // Post the event to the location.
            postEvent(event, to: location, token:token)
        }
    }

    /// Does a lot of weird magic to make a menu bar item receive an event.
    ///
    /// - Parameters:
    ///   - event: The event to send.
    ///   - firstLocation: The first location to send the event to.
    ///   - secondLocation: The second location to send the event to.
    ///   - item: The menu bar item that the event affects.
    private func scrombleEvent(
        _ event: CGEvent,
        from firstLocation: EventTap.Location,
        to secondLocation: EventTap.Location,
        item: MenuBarItem,
        token: NativeInteractionLifecycle.Token? = nil
    ) async throws {
        guard let token = token ?? nativeLifecycle.token(), nativeLifecycle.accepts(token) else { throw CancellationError() }
        // Create a null event and assign it unique user data.
        guard let nullEvent = CGEvent(source: nil) else {
            throw EventError(code: .eventCreationFailure, item: item)
        }
        let nullUserData = Int64(truncatingIfNeeded: Int(bitPattern: ObjectIdentifier(nullEvent)))
        nullEvent.setIntegerValueField(.eventSourceUserData, value: nullUserData)

        return try await withCheckedThrowingContinuation { continuation in
            // Create an event tap for the null event at the first location.
            // This tap throws away all events it receives.
            let eventTap1 = EventTap(
                label: "EventTap 1",
                options: .defaultTap,
                location: firstLocation,
                place: .tailAppendEventTap,
                types: [nullEvent.type]
            ) { [weak self] proxy, type, rEvent in
                guard let self else {
                    proxy.disable()
                    return nil
                }

                // Reenable the tap if disabled by the system.
                if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
                    proxy.enable()
                    return nil
                }

                // Verify that this is the null event.
                guard rEvent.getIntegerValueField(.eventSourceUserData) == nullUserData else {
                    return nil
                }

                guard nativeLifecycle.accepts(token) else { proxy.disable(); return nil }
                // Disable the tap and post the real event to the second location.
                proxy.disable()
                postEvent(event, to: secondLocation, token:token)

                return nil
            }

            // Create an event tap for the real event at the second location.
            // This tap can listen for events, but cannot alter or discard them.
            let eventTap2 = EventTap(
                label: "EventTap 2",
                options: .listenOnly,
                location: secondLocation,
                place: .tailAppendEventTap,
                types: [event.type]
            ) { [weak self] proxy, type, rEvent in
                guard let self else {
                    proxy.disable()
                    return nil
                }

                // Reenable the tap if disabled by the system.
                if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
                    proxy.enable()
                    return nil
                }

                // Verify that the received event was the sent event.
                guard eventsMatch([rEvent, event], by: [.eventSourceUserData]) else {
                    return nil
                }

                if !nativeLifecycle.accepts(token) {
                    proxy.disable(); continuation.resume(throwing:CancellationError()); return nil
                }
                // Ensure the tap is enabled, preventing multiple calls to resume().
                guard proxy.isEnabled else {
                    Logger.itemManager.debug("Event tap \"\(proxy.label)\" is disabled (item: \(item.logString))")
                    return nil
                }

                // Disable the tap, post the event to the first location, and resume
                // the continuation.
                proxy.disable()
                postEvent(event, to: firstLocation, token:token)
                continuation.resume()

                return nil
            }

            // Enable both taps, with a timeout on the second tap.
            eventTap1.enable()
            eventTap2.enable(timeout: .milliseconds(250)) {
                Logger.itemManager.error("Event tap \"\(eventTap2.label)\" timed out (item: \(item.logString))")
                eventTap1.disable()
                eventTap2.disable()
                continuation.resume(throwing: EventError(code: .eventOperationTimeout, item: item))
            }

            // Post the null event to the first location.
            postEvent(nullEvent, to: firstLocation, token:token)
        }
    }

    /// Does a lot of weird magic to make a menu bar item receive an event, then
    /// waits for the frame of the given menu bar item to change before returning.
    ///
    /// - Parameters:
    ///   - event: The event to send.
    ///   - firstLocation: The first location to send the event to.
    ///   - secondLocation: The second location to send the event to.
    ///   - item: The item whose frame should be observed.
    private func scrombleEvent(
        _ event: CGEvent,
        from firstLocation: EventTap.Location,
        to secondLocation: EventTap.Location,
        waitingForFrameChangeOf item: MenuBarItem,
        token: NativeInteractionLifecycle.Token? = nil
    ) async throws {
        guard let token = token ?? nativeLifecycle.token(), nativeLifecycle.accepts(token) else { throw CancellationError() }
        guard let currentFrame = getCurrentFrame(for: item) else {
            try await scrombleEvent(event, from: firstLocation, to: secondLocation, item: item, token:token)
            Logger.itemManager.warning("Couldn't get menu bar item frame for \(item.logString), so using fixed delay")
            // This will be slow, but subsequent events will have a better chance of succeeding.
            try await Task.sleep(for: .milliseconds(50))
            return
        }
        try await scrombleEvent(event, from: firstLocation, to: secondLocation, item: item, token:token)
        // 500ms rather than 50ms: Control Center on macOS 26 batches menu bar
        // layout, and frame changes regularly land after 50ms. The wait polls,
        // so successful moves return as soon as the frame actually changes.
        guard nativeLifecycle.accepts(token) else { throw CancellationError() }
        try await waitForFrameChange(of: item, initialFrame: currentFrame, timeout: .milliseconds(500), token:token)
    }

    /// Waits for a menu bar item's frame to change from an initial frame.
    ///
    /// - Parameters:
    ///   - item: The item whose frame should be observed.
    ///   - initialFrame: An initial frame to compare the item's frame against.
    ///   - timeout: The amount of time to wait before throwing a timeout error.
    private func waitForFrameChange(of item: MenuBarItem, initialFrame: CGRect, timeout: Duration, token: NativeInteractionLifecycle.Token? = nil) async throws {
        struct FrameCheckCancellationError: Error { }

        let frameCheckTask = Task(timeout: timeout) {
            while true {
                try Task.checkCancellation()
                if let token, !self.nativeLifecycle.accepts(token) { throw CancellationError() }
                guard let currentFrame = await self.getCurrentFrame(for: item) else {
                    throw FrameCheckCancellationError()
                }
                if currentFrame != initialFrame {
                    Logger.itemManager.debug("Menu bar item frame for \(item.logString) has changed to \(NSStringFromRect(currentFrame))")
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        do {
            try await withTaskCancellationHandler(operation:{ try await frameCheckTask.value },onCancel:{ frameCheckTask.cancel() })
        } catch is FrameCheckCancellationError {
            Logger.itemManager.warning("Menu bar item frame check for \(item.logString) was cancelled, so using fixed delay")
            // This will be slow, but subsequent events will have a better chance of succeeding.
            try await Task.sleep(for: .milliseconds(50))
        } catch is TaskTimeoutError {
            throw EventError(code: .frameCheckTimeout, item: item)
        }
    }

    /// Permits all events for an event source during the given suppression states,
    /// suppressing local events for the given interval.
    private func permitAllEvents(
        for stateID: CGEventSourceStateID,
        during states: [CGEventSuppressionState],
        suppressionInterval: TimeInterval,
        item: MenuBarItem
    ) throws {
        guard let source = CGEventSource(stateID: stateID) else {
            throw EventError(code: .invalidEventSource, item: item)
        }
        for state in states {
            source.setLocalEventsFilterDuringSuppressionState(.permitAllEvents, state: state)
        }
        source.localEventsSuppressionInterval = suppressionInterval
    }

    /// Tries to wake up the given item if it is not responding to events.
    private func wakeUpItem(_ item: MenuBarItem) async throws {
        guard let token = nativeLifecycle.token() else { throw CancellationError() }
        Logger.itemManager.debug("Attempting to wake up \(item.logString)")

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw EventError(code: .invalidEventSource, item: item)
        }
        guard let currentFrame = getCurrentFrame(for: item) else {
            throw EventError(code: .invalidItem, item: item)
        }

        guard
            let mouseDownEvent = CGEvent.menuBarItemEvent(
                type: .move(.leftMouseDown),
                location: CGPoint(x: currentFrame.midX, y: currentFrame.midY),
                item: item,
                pid: item.ownerPID,
                source: source
            ),
            let mouseUpEvent = CGEvent.menuBarItemEvent(
                type: .move(.leftMouseUp),
                location: CGPoint(x: currentFrame.midX, y: currentFrame.midY),
                item: item,
                pid: item.ownerPID,
                source: source
            )
        else {
            throw EventError(code: .eventCreationFailure, item: item)
        }

        let press = armSyntheticPress(down:mouseDownEvent,release:mouseUpEvent,item:item)
        defer { finishSyntheticPress(press) }
        try await scrombleEvent(
            mouseDownEvent,
            from: .pid(item.ownerPID),
            to: .sessionEventTap,
            item: item,
            token:token
        )
        try await scrombleEvent(
            mouseUpEvent,
            from: .pid(item.ownerPID),
            to: .sessionEventTap,
            item: item,
            token:token
        )
    }

    /// Moves a menu bar item to the given destination, without restoring the mouse
    /// pointer to its initial location.
    ///
    /// - Parameters:
    ///   - item: A menu bar item to move.
    ///   - destination: A destination to move the menu bar item.
    private func moveItemWithoutRestoringMouseLocation(_ item: MenuBarItem, to destination: MoveDestination, token: NativeInteractionLifecycle.Token,
                                                      completion: ((CGRect) -> Bool)? = nil) async throws {
        guard nativeLifecycle.accepts(token) else { throw CancellationError() }
        itemMoveCount += 1
        defer {
            itemMoveCount -= 1
        }

        guard item.isMovable else {
            throw EventError(code: .notMovable, item: item)
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw EventError(code: .invalidEventSource, item: item)
        }

        let startPoint = CGPoint(x: 20_000, y: 20_000)
        let fallbackPoint = try getFallbackPoint(for: item)
        let targetItem = getTargetItem(for: destination)

        guard
            let mouseDownEvent = CGEvent.menuBarItemEvent(
                type: .move(.leftMouseDown),
                location: startPoint,
                item: item,
                pid: item.ownerPID,
                source: source
            ),
            let fallbackEvent = CGEvent.menuBarItemEvent(
                type: .move(.leftMouseUp),
                location: fallbackPoint,
                item: item,
                pid: item.ownerPID,
                source: source
            )
        else {
            throw EventError(code: .eventCreationFailure, item: item)
        }

        try permitAllEvents(
            for: .combinedSessionState,
            during: [
                .eventSuppressionStateRemoteMouseDrag,
                .eventSuppressionStateSuppressionInterval,
            ],
            suppressionInterval: 0,
            item: item
        )

        let press = armSyntheticPress(down:mouseDownEvent,release:fallbackEvent,item:item)
        defer { finishSyntheticPress(press) }
        lastItemMoveStartDate = .now
        var releaseAttempted = false

        do {
            try await scrombleEvent(
                mouseDownEvent,
                from: .pid(item.ownerPID),
                to: .sessionEventTap,
                waitingForFrameChangeOf: item,
                token:token
            )

            // Compute the release point only AFTER the pickup: picking the item
            // up reflows the whole bar on macOS 26 (the section divider resizes
            // for cross-section moves), so a pre-pickup release point is stale
            // and drops the item one slot off — visible as items landing on the
            // wrong side of the target and hopping into place on retry.
            guard nativeLifecycle.accepts(token) else { throw CancellationError() }
            let endPoint = try getEndPoint(for: destination)
            if LayoutDiagnostics.isEnabled {
                let targetFrame = Bridging.getWindowFrame(for: targetItem.windowID)
                LayoutDiagnostics.appendText(
                    "[move-release] item wid=\(item.windowID) | target wid=\(targetItem.windowID) at \(targetFrame.map(String.init(describing:)) ?? "<nil>") | releasing at \(endPoint) (post-pickup)"
                )
            }
            guard
                let mouseUpEvent = CGEvent.menuBarItemEvent(
                    type: .move(.leftMouseUp),
                    location: endPoint,
                    item: targetItem,
                    pid: item.ownerPID,
                    source: source
                )
            else {
                throw EventError(code: .eventCreationFailure, item: item)
            }

            nativeLifecycle.includeUpTag(mouseUpEvent.getIntegerValueField(.eventSourceUserData))
            releaseAttempted = true
            try await scrombleEvent(
                mouseUpEvent,
                from: .pid(item.ownerPID),
                to: .sessionEventTap,
                waitingForFrameChangeOf: item,
                token:token
            )
        } catch {
            if !nativeLifecycle.accepts(token) { releaseSyntheticPress(press); throw CancellationError() }
            if releaseAttempted {
                if (try? itemHasCorrectPosition(item:item,for:destination)) == true { return }
                if let completion, let frame=getCurrentFrame(for:item),completion(frame) { return }
            }
            do {
                Logger.itemManager.debug("Posting fallback event for moving \(item.logString)")
                // Catch this, as we still want to throw the existing error if the fallback fails.
                try await postEventAndWaitToReceive(
                    fallbackEvent,
                    to: .sessionEventTap,
                    item: item,
                    token:token
                )
            } catch {
                Logger.itemManager.error("Failed to post fallback event for moving \(item.logString)")
            }
            throw error
        }
    }

    /// Moves a menu bar item to the given destination.
    ///
    /// - Parameters:
    ///   - item: A menu bar item to move.
    ///   - destination: A destination to move the menu bar item.
    func move(item: MenuBarItem, to destination: MoveDestination, allowHeldModifiers: Bool = false,
              allowDuringTermination: Bool = false) async throws {
        guard let token = nativeLifecycle.token(restoration:allowDuringTermination) else { throw CancellationError() }
        activeNativeWorkCount += 1
        defer { activeNativeWorkCount -= 1 }
        if try itemHasCorrectPosition(item: item, for: destination) {
            Logger.itemManager.debug("\(item.logString) is already in the correct position")
            return
        }

        do {
            // Order of these waiters matters, as the modifiers could be released
            // while the mouse is still moving.
            if !allowHeldModifiers { try await waitForNoModifiersPressed(timeout: .milliseconds(500)) }
            try await waitForMouseToStopMoving(timeout: .milliseconds(500))
        } catch {
            throw EventError(code: .couldNotComplete, item: item)
        }

        guard nativeLifecycle.accepts(token) else { throw CancellationError() }
        Logger.itemManager.info("Moving \(item.logString) to \(destination.logString)")

        guard let appState else {
            throw EventError(code: .invalidAppState, item: item)
        }
        guard let cursorLocation = MouseCursor.locationCoreGraphics else {
            throw EventError(code: .invalidCursorLocation, item: item)
        }
        guard let initialFrame = getCurrentFrame(for: item) else {
            throw EventError(code: .invalidItem, item: item)
        }

        appState.eventManager.stopAll()
        defer {
            appState.eventManager.startAll()
        }

        let cursorLease = beginCursorLease(returnTo:cursorLocation)
        defer { endCursorLease(cursorLease) }

        // Item movement can occasionally fail. Retry up to a total of 5 attempts,
        // throwing the last attempt's error if it fails.
        for n in 1...5 {
            do {
                guard nativeLifecycle.accepts(token) else { throw CancellationError() }
                try await moveItemWithoutRestoringMouseLocation(item, to: destination, token:token)
                guard let newFrame = getCurrentFrame(for: item) else {
                    throw EventError(code: .invalidItem, item: item)
                }
                if newFrame != initialFrame {
                    Logger.itemManager.info("Successfully moved \(item.logString)")
                    break
                } else {
                    throw EventError(code: .couldNotComplete, item: item)
                }
            } catch {
                guard nativeLifecycle.accepts(token) else { throw CancellationError() }
                // Tahoe can complete the drop before its event acknowledgement.
                // A verified destination wins over a missing acknowledgement.
                if (try? itemHasCorrectPosition(item: item, for: destination)) == true { return }
                guard n < 5 else { throw error }
                Logger.itemManager.warning("Attempt \(n) to move \(item.logString) failed (error: \(error))")
                try await wakeUpItem(item)
                Logger.itemManager.info("Retrying move of \(item.logString)")
                continue
            }
        }
    }

    /// Temporary interaction has a visibility contract, not an ordering contract.
    /// Native fixed gaps/reflow must not force extra drags after the click point
    /// has reached the correct display's safe menu area.
    private func revealToClickableArea(_ item: MenuBarItem, before target: MenuBarItem,
                                       display: CGRect, minimumX: CGFloat) async throws {
        guard let token=nativeLifecycle.token(),let appState else { throw CancellationError() }
        activeNativeWorkCount += 1;itemMoveCount += 1
        defer { activeNativeWorkCount -= 1;itemMoveCount -= 1 }
        let visible: (CGRect) -> Bool = { frame in
            NativeInteractionPolicy.isClickCenterSafe(frame:frame,
                isOnScreen:MenuBarItem(windowID:item.windowID)?.isOnScreen ?? false,
                display:display,minimumX:minimumX)
        }
        if let frame=getCurrentFrame(for:item),visible(frame) { return }
        try await waitForMouseToStopMoving(threshold:0.05,timeout:.milliseconds(500))
        guard nativeLifecycle.accepts(token) else { throw CancellationError() }
        let lease=beginCursorLease(returnTo:MouseCursor.locationCoreGraphics)
        defer { endCursorLease(lease) }
        appState.eventManager.stopAll()
        defer { appState.eventManager.startAll() }
        var lastError: Error=EventError(code:.couldNotComplete,item:item)
        for attempt in 1...3 {
            guard nativeLifecycle.accepts(token) else { throw CancellationError() }
            if let frame=getCurrentFrame(for:item),visible(frame) { return }
            traceNativeClick("reveal-move-start",item:item,details:["attempt":attempt,"targetWindowID":target.windowID,
                "targetFrame":NSStringFromRect(Bridging.getWindowFrame(for:target.windowID) ?? .zero)])
            do {
                try await moveItemWithoutRestoringMouseLocation(item,to:.leftOfItem(target),token:token,completion:visible)
            } catch {
                guard nativeLifecycle.accepts(token) else { throw CancellationError() }
                lastError=error
                traceNativeClick("reveal-move-error",item:item,details:["error":error.localizedDescription,"attempt":attempt])
            }
            let settleUntil=ProcessInfo.processInfo.systemUptime+0.3
            repeat {
                guard nativeLifecycle.accepts(token) else { throw CancellationError() }
                let frame=getCurrentFrame(for:item)
                let safe=frame.map(visible) ?? false
                traceNativeClick("reveal-visible-check",item:item,details:["safe":safe,"minimumX":minimumX,
                    "display":NSStringFromRect(display),"attempt":attempt])
                if safe { return }
                try await Task.sleep(for:.milliseconds(20))
            } while ProcessInfo.processInfo.systemUptime<settleUntil
        }
        throw lastError
    }

    /// Moves a menu bar item to the given destination and waits until the move
    /// completes before returning.
    /// 
    /// - Parameters:
    ///   - item: A menu bar item to move.
    ///   - destination: A destination to move the menu bar item.
    ///   - timeout: Amount of time to wait before throwing an error.
    func slowMove(item: MenuBarItem, to destination: MoveDestination, timeout: Duration = .seconds(1), allowHeldModifiers: Bool = false,
                  allowDuringTermination: Bool = false) async throws {
        guard let token = nativeLifecycle.token(restoration:allowDuringTermination) else { throw CancellationError() }
        activeNativeWorkCount += 1
        defer { activeNativeWorkCount -= 1 }
        itemMoveCount += 1
        defer {
            itemMoveCount -= 1
        }
        // Cross-section moves reflow the whole bar mid-gesture on Tahoe, which
        // can invalidate the release coordinates and drop the item one slot
        // off. Retrying recomputes the drop point from fresh frames, so a
        // short retry loop converges instead of failing.
        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            try await move(item: item, to: destination, allowHeldModifiers: allowHeldModifiers, allowDuringTermination:allowDuringTermination)
            guard nativeLifecycle.accepts(token) else { throw CancellationError() }
            let waitTask = Task(timeout: timeout) {
                while true {
                    try Task.checkCancellation()
                    guard self.nativeLifecycle.accepts(token) else { throw CancellationError() }
                    if try await self.itemHasCorrectPosition(item: item, for: destination) {
                        return
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
            do {
                try await withTaskCancellationHandler(operation:{ try await waitTask.value },onCancel:{ waitTask.cancel() })
                LayoutDiagnostics.appendText("[slowMove-ok] item wid=\(item.windowID) verified at destination (attempt \(attempt))")
                return
            } catch is TaskTimeoutError {
                guard attempt < maxAttempts else {
                    logSlowMoveTimeoutEvidence(item: item, destination: destination)
                    throw EventError(code: .otherTimeout, item: item)
                }
                LayoutDiagnostics.appendText("[slowMove-retry] item wid=\(item.windowID) attempt \(attempt) failed verification, retrying")
            }
        }
    }

    /// Diagnostic evidence gathering for slowMove verification timeouts: logs
    /// high-precision frames of the item and target at timeout, +1s, and +3s,
    /// to distinguish sub-pixel mismatch from animation-lag from never-adjacent.
    private func logSlowMoveTimeoutEvidence(item: MenuBarItem, destination: MoveDestination) {
        guard LayoutDiagnostics.isEnabled else {
            return
        }
        let target = getTargetItem(for: destination)
        let expectation = switch destination {
        case .leftOfItem: "item.maxX == target.minX"
        case .rightOfItem: "item.minX == target.maxX"
        }
        func sample(_ label: String) {
            let itemFrame = Bridging.getWindowFrame(for: item.windowID)
            let targetFrame = Bridging.getWindowFrame(for: target.windowID)
            func fmt(_ frame: CGRect?) -> String {
                guard let frame else {
                    return "<nil>"
                }
                return String(
                    format: "(%.4f, %.4f, %.4f x %.4f) minX=%.4f maxX=%.4f",
                    frame.origin.x, frame.origin.y, frame.width, frame.height, frame.minX, frame.maxX
                )
            }
            LayoutDiagnostics.appendText(
                "[slowMove-timeout \(label)] item wid=\(item.windowID) \(fmt(itemFrame)) | target wid=\(target.windowID) \(fmt(targetFrame)) | expect \(expectation)"
            )
        }
        sample("t+0s")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            sample("t+1s")
            try? await Task.sleep(for: .seconds(2))
            sample("t+3s")
        }
    }
}

// MARK: - Click Items

extension MenuBarItemManager {
    /// Send a plain click through the *source application's* event stream.
    /// A null-entry/exit barrier follows Icey's Tahoe path. Seeing an event at
    /// the session tap alone does not establish delivery to the client.
    private func postClickEventWithBarrier(_ event: CGEvent, item: MenuBarItem,
                                          repeating repeatCount: Int = 1,
                                          token: NativeInteractionLifecycle.Token) async throws {
        guard nativeLifecycle.accepts(token), let entry=CGEvent(source:nil),let exit=CGEvent(source:nil) else {
            throw CancellationError()
        }
        let pid=item.sourcePID ?? item.ownerPID
        let entryTag=Int64(truncatingIfNeeded:Int(bitPattern:ObjectIdentifier(entry)))
        let exitTag=Int64(truncatingIfNeeded:Int(bitPattern:ObjectIdentifier(exit)))
        entry.setIntegerValueField(.eventSourceUserData,value:entryTag)
        exit.setIntegerValueField(.eventSourceUserData,value:exitTag)
        event.setIntegerValueField(.eventTargetUnixProcessID,value:Int64(pid))
        let completion=NativeEventCompletion()
        var count=max(1,repeatCount)
        var ownerTap: EventTap?, sessionTap: EventTap?
        defer { ownerTap?.disable();sessionTap?.disable();ownerTap=nil;sessionTap=nil }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                guard !completion.isFinished,nativeLifecycle.accepts(token),!Task.isCancelled else {
                    completion.finish(.failure(CancellationError()));return
                }
                ownerTap=EventTap(label:"Native click source barrier",options:.defaultTap,
                    location:.pid(pid),place:.headInsertEventTap,types:[.null]) { [weak self] proxy,type,received in
                    guard let self else { proxy.disable();completion.finish(.failure(CancellationError()));return nil }
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { proxy.enable();return received }
                    let tag=received.getIntegerValueField(.eventSourceUserData)
                    guard tag == entryTag || tag == exitTag else { return received }
                    guard self.nativeLifecycle.accepts(token) else {
                        proxy.disable();sessionTap?.disable();completion.finish(.failure(CancellationError()));return nil
                    }
                    if tag == entryTag {
                        count -= 1
                        self.traceNativeClick("source-entry",item:item,event:event,details:["repeatRemaining":count])
                        self.postEvent(event,to:.sessionEventTap,token:token)
                    } else {
                        proxy.disable();sessionTap?.disable()
                        self.traceNativeClick("source-exit",item:item,event:event)
                        completion.finish(.success(()))
                    }
                    return nil
                }
                sessionTap=EventTap(label:"Native click session delivery",options:.listenOnly,
                    location:.sessionEventTap,place:.tailAppendEventTap,types:[event.type]) { [weak self] proxy,type,received in
                    guard let self else { proxy.disable();completion.finish(.failure(CancellationError()));return nil }
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { proxy.enable();return received }
                    guard received.getIntegerValueField(.eventSourceUserData) == event.getIntegerValueField(.eventSourceUserData) else { return received }
                    guard self.nativeLifecycle.accepts(token) else {
                        proxy.disable();ownerTap?.disable();completion.finish(.failure(CancellationError()));return received
                    }
                    // WindowServer may rewrite target routing while annotating
                    // hosted status items. Preserve the original client PID.
                    received.setIntegerValueField(.eventTargetUnixProcessID,value:Int64(pid))
                    self.traceNativeClick("session-delivery",item:item,event:received,details:["repeatRemaining":count])
                    self.postEvent(count>0 ? entry : exit,to:.pid(pid),token:token)
                    return received
                }
                ownerTap?.enable(timeout:.milliseconds(250*max(1,repeatCount))) { [weak self] in
                    ownerTap?.disable();sessionTap?.disable()
                    self?.traceNativeClick("barrier-timeout",item:item,event:event)
                    completion.finish(.failure(EventError(code:.eventOperationTimeout,item:item)))
                }
                sessionTap?.enable()
                traceNativeClick("barrier-start",item:item,event:event,details:["repeatCount":max(1,repeatCount)])
                postEvent(entry,to:.pid(pid),token:token)
            }
        } onCancel: { completion.finish(.failure(CancellationError())) }
    }

    private func traceNativeClick(_ phase: String, item: MenuBarItem, event: CGEvent? = nil, details: [String:Any] = [:]) {
        let args=ProcessInfo.processInfo.arguments
        guard let index=args.firstIndex(of:"--diagnostics-path"),args.indices.contains(index+1) else { return }
        var payload=details
        payload["phase"]=phase;payload["timestamp"]=Date().timeIntervalSince1970
        payload["hostPID"]=item.ownerPID;payload["sourcePID"]=item.sourcePID ?? item.ownerPID
        payload["windowID"]=item.windowID;payload["key"]=item.info.description
        payload["frame"]=NSStringFromRect(Bridging.getWindowFrame(for:item.windowID) ?? .zero)
        if let event {
            payload["eventType"]=event.type.rawValue;payload["targetPID"]=event.getIntegerValueField(.eventTargetUnixProcessID)
            payload["clickState"]=event.getIntegerValueField(.mouseEventClickState)
            payload["privateWindowID"]=event.getIntegerValueField(CGEventField(rawValue:0x33)!)
            payload["windowUnderPointer"]=event.getIntegerValueField(.mouseEventWindowUnderMousePointer)
            payload["modifiers"]=event.flags.rawValue
            payload["point"]="\(event.location)"
        }
        guard let json=try? JSONSerialization.data(withJSONObject:payload,options:.sortedKeys) else { return }
        let url=URL(fileURLWithPath:args[index+1]).deletingPathExtension().appendingPathExtension("native-click.jsonl")
        var line=json;line.append(10)
        if !FileManager.default.fileExists(atPath:url.path) { FileManager.default.createFile(atPath:url.path,contents:line) }
        else if let handle=try? FileHandle(forWritingTo:url) { try? handle.seekToEnd();try? handle.write(contentsOf:line);try? handle.close() }
    }

    /// Clicks the given menu bar item with the given mouse button.
    func click(item: MenuBarItem, with mouseButton: CGMouseButton, modifiers: CGEventFlags = [], clickCount: Int = 1) async throws {
        guard let token = nativeLifecycle.token() else { throw CancellationError() }
        activeNativeWorkCount += 1
        defer { activeNativeWorkCount -= 1 }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw EventError(code: .invalidEventSource, item: item)
        }
        guard let cursorLocation = MouseCursor.locationCoreGraphics else {
            throw EventError(code: .invalidCursorLocation, item: item)
        }
        guard let currentFrame = getCurrentFrame(for: item) else {
            throw EventError(code: .invalidItem, item: item)
        }

        let buttonStates = mouseButton.buttonStates
        let clickPoint = CGPoint(x: currentFrame.midX, y: currentFrame.midY)
        guard NSScreen.screens.contains(where:{ CGDisplayBounds($0.displayID).contains(clickPoint) }) else {
            throw EventError(code:.invalidItem,item:item)
        }
        let eventPID=item.sourcePID ?? item.ownerPID

        guard
            let mouseDownEvent = CGEvent.menuBarItemEvent(
                type: .click(buttonStates.down),
                location: clickPoint,
                item: item,
                pid: eventPID,
                source: source
            ),
            let mouseUpEvent = CGEvent.menuBarItemEvent(
                type: .click(buttonStates.up),
                location: clickPoint,
                item: item,
                pid: eventPID,
                source: source
            ),
            let fallbackEvent = CGEvent.menuBarItemEvent(
                type: .click(buttonStates.up),
                location: clickPoint,
                item: item,
                pid: eventPID,
                source: source
            )
        else {
            throw EventError(code: .eventCreationFailure, item: item)
        }

        for event in [mouseDownEvent, mouseUpEvent, fallbackEvent] {
            event.flags = modifiers
            let down=event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown
            event.setIntegerValueField(.mouseEventClickState,value:down ? Int64(max(1,clickCount)) : 0)
        }

        try permitAllEvents(
            for: .combinedSessionState,
            during: [
                .eventSuppressionStateRemoteMouseDrag,
                .eventSuppressionStateSuppressionInterval,
            ],
            suppressionInterval: 0,
            item: item
        )

        let cursorLease = beginCursorLease(returnTo:cursorLocation)
        defer { endCursorLease(cursorLease) }
        let press = armSyntheticPress(down:mouseDownEvent,release:fallbackEvent,item:item,
            alternateRelease:mouseUpEvent)
        defer { finishSyntheticPress(press) }

        do {
            traceNativeClick("click-start",item:item,event:mouseDownEvent)
            try await postClickEventWithBarrier(mouseDownEvent,item:item,token:token)
            try await postClickEventWithBarrier(mouseUpEvent,item:item,repeating:2,token:token)
            traceNativeClick("click-dispatched",item:item,event:mouseUpEvent,
                details:["verification":"transport-only; native client callback/UI still required"])
        } catch {
            if !nativeLifecycle.accepts(token) { releaseSyntheticPress(press);throw CancellationError() }
            do { try await postClickEventWithBarrier(fallbackEvent,item:item,repeating:2,token:token) }
            catch { traceNativeClick("click-fallback-failed",item:item,event:fallbackEvent) }
            throw error
        }
    }
}

// MARK: - Temporarily Show Items

extension MenuBarItemManager {
    /// Gets the destination to return the given item to after it is temporarily shown.
    private func getReturnDestination(for item: MenuBarItem, in items: [MenuBarItem]) -> MoveDestination? {
        if let index = items.firstIndex(where: { $0.windowID == item.windowID }) {
            if items.indices.contains(index + 1) {
                return .leftOfItem(items[index + 1])
            } else if items.indices.contains(index - 1) {
                return .rightOfItem(items[index - 1])
            }
        }
        return nil
    }

    /// Schedules a timer for the given interval, attempting to rehide the current
    /// temporarily shown items when the timer fires.
    private func runTempShownItemTimer(for interval: TimeInterval) {
        guard !nativeLifecycle.isStopping else { return }
        Logger.itemManager.debug("Running rehide timer for temporarily shown items with interval: \(interval)")
        tempShownItemsTimer?.invalidate()
        tempShownItemsTimer = Timer(timeInterval: interval, repeats: false) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            Logger.itemManager.debug("Rehide timer fired")
            Task {
                await self.rehideTempShownItems()
            }
        }
        if let timer = tempShownItemsTimer { RunLoop.main.add(timer, forMode: .common) }
    }

    /// Temporarily shows the given item.
    ///
    /// The item is cached alongside a destination that it will be automatically returned
    /// to. If `true` is passed to the `clickWhenFinished` parameter, the item is clicked
    /// once movement is finished.
    ///
    /// - Parameters:
    ///   - item: An item to show.
    ///   - clickWhenFinished: A Boolean value that indicates whether the item should be
    ///     clicked once movement is finished.
    ///   - mouseButton: The mouse button of the click.
    func tempShowItem(_ item: MenuBarItem, clickWhenFinished: Bool, mouseButton: CGMouseButton) {
        Task {
            do { try await revealAndClick(item, clickWhenFinished: clickWhenFinished, mouseButton: mouseButton) }
            catch { appState?.shelfManager.message = "无法打开 \(item.displayName)：\(error.localizedDescription)" }
        }
    }

    func revealAndClick(_ item: MenuBarItem, clickWhenFinished: Bool = true, mouseButton: CGMouseButton,
                        modifiers: CGEventFlags = [], clickCount: Int = 1) async throws {
        guard let token = nativeLifecycle.token(), !isOpeningInterface, let appState, let latest = MenuBarItem(windowID: item.windowID) else {
            throw EventError(code: .invalidItem, item: item)
        }
        traceNativeClick("reveal-start",item:latest,details:["initialOnScreen":latest.isOnScreen])
        isOpeningInterface = true; activeNativeWorkCount += 1
        defer { isOpeningInterface = false; activeNativeWorkCount -= 1 }
        let screens = NSScreen.screens
        let preferredScreen = NSScreen.screenWithMouse
        let preferredIndex = preferredScreen.flatMap { selected in screens.firstIndex { $0.displayID == selected.displayID } }
        let screenIndex = NativeInteractionPolicy.displayIndex(frame:latest.frame,
            displays:screens.map { CGDisplayBounds($0.displayID) },preferredIndex:preferredIndex)
        let screen = screenIndex.map { screens[$0] } ?? NSScreen.main
        guard let screen else { throw EventError(code: .couldNotComplete, item: item) }
        let display = CGDisplayBounds(screen.displayID)
        let appMenuMaxX = appState.menuBarManager.getApplicationMenuFrame(for: screen.displayID)?.maxX ?? display.minX
        let minimumX = max(screen.auxiliaryTopRightArea?.minX ?? display.minX, appMenuMaxX)
        if NativeInteractionPolicy.isClickCenterSafe(frame:latest.frame,isOnScreen:latest.isOnScreen,
                                                    display:display,minimumX:minimumX) {
            if clickWhenFinished {
                guard nativeLifecycle.accepts(token) else { throw CancellationError() }
                try await appState.menuCover.passthrough {
                    try await self.click(item: latest, with: mouseButton, modifiers: modifiers, clickCount: clickCount)
                }
                if let index = tempShownItemContexts.firstIndex(where: { $0.windowID == latest.windowID }) {
                    try? await Task.sleep(for: .milliseconds(150))
                    refreshShownInterfaces(at: index)
                    runTempShownItemTimer(for: 1)
                }
            }
            return
        }
        guard latest.isMovable else { throw EventError(code: .notMovable, item: item) }
        let all = MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true)
        guard let dividerIndex = all.firstIndex(where: { $0.info == .hiddenControlItem }),
              let destination = getReturnDestination(for: latest, in: all) else {
            throw EventError(code: .invalidItem, item: item)
        }
        let candidates = all.dropFirst(dividerIndex+1).filter {
            $0.windowID != latest.windowID &&
            NativeInteractionPolicy.isClickable(frame: $0.frame, isOnScreen: $0.isOnScreen,
                                                  display: display, minimumX: minimumX)
        }
        guard let target = candidates.first(where: { $0.frame.minX-latest.frame.width/2 > minimumX+8 }) else {
            throw EventError(code: .couldNotComplete, item: item)
        }
        let section = itemCache.section(for: latest) ?? (latest.frame.maxX <= all[dividerIndex].frame.minX ? .hidden : .visible)
        let menuBand = CGRect(x: display.minX, y: display.minY, width: display.width,
                              height: screen.getMenuBarHeight() ?? NSStatusBar.system.thickness)
        let initialIDs = Set(WindowInfo.getOnScreenWindows().map(\.windowID))
        // Record the return before moving. A move acknowledgement or subsequent
        // click may fail after the item has already become visible.
        if !tempShownItemContexts.contains(where: { $0.windowID == latest.windowID }) {
            tempShownItemContexts.append(TempShownItemContext(windowID: latest.windowID, info: latest.info,
                returnDestination: destination, returnSection: section, sourcePID: latest.sourcePID,
                menuBand:menuBand,originalOnScreenWindowIDs:initialIDs,
                originalFrame:Bridging.getWindowFrame(for:latest.windowID) ?? latest.frame,
                originalWindowOrder:NativeReturnEvidence.unique(all.map(\.windowID)),originalOnScreen:latest.isOnScreen))
        }
        do {
            // Synthetic pickup has its own Command flag. Holding Option/Shift for
            // the final original-app click must not delay or alter this move.
            try await revealToClickableArea(latest,before:target,display:display,minimumX:minimumX)
            guard nativeLifecycle.accepts(token) else { throw CancellationError() }
            guard let shown = MenuBarItem(windowID: latest.windowID),
                  NativeInteractionPolicy.isClickCenterSafe(frame:shown.frame,isOnScreen:shown.isOnScreen,
                                                          display:display,minimumX:minimumX) else {
                throw EventError(code: .couldNotComplete, item: latest)
            }
            traceNativeClick("reveal-ready",item:shown,details:["onScreen":shown.isOnScreen,"minimumX":minimumX,"display":NSStringFromRect(display)])
            if clickWhenFinished {
                guard nativeLifecycle.accepts(token) else { throw CancellationError() }
                try await appState.menuCover.passthrough {
                    try await self.click(item: shown, with: mouseButton, modifiers: modifiers, clickCount: clickCount)
                }
            }
            try? await Task.sleep(for: .milliseconds(150))
            if let index = tempShownItemContexts.firstIndex(where: { $0.windowID == latest.windowID }) {
                refreshShownInterfaces(at: index)
            }
            runTempShownItemTimer(for: clickWhenFinished ? 1 : 3)
            await refreshItems()
        } catch {
            traceNativeClick("reveal-failed",item:latest,details:["error":error.localizedDescription])
            // Restore the item even when a partial move succeeded. The common-mode
            // timer retries after a held mouse button/key or a transient failure.
            runTempShownItemTimer(for: 1)
            throw error
        }
    }

    private func refreshShownInterfaces(at index: Int) {
        guard tempShownItemContexts.indices.contains(index) else { return }
        let context = tempShownItemContexts[index]
        let windows = WindowInfo.getOnScreenWindows().filter { window in
            guard window.windowID != context.windowID,
                  window.ownerPID != ProcessInfo.processInfo.processIdentifier,
                  NativeInteractionPolicy.retainsTemporaryItem(layer: window.layer, frame: window.frame,
                    popupLayer: Int(CGWindowLevelForKey(.popUpMenuWindow)), menuBand: context.menuBand) else { return false }
            if let source = context.sourcePID {
                return MenuBarSourceResolver.sameApplicationFamily(source, window.ownerPID)
            }
            // With unknown source metadata, retain only a newly presented popup.
            // Its identity is never used to route an app action.
            return !context.originalOnScreenWindowIDs.contains(window.windowID)
        }
        for window in windows where !tempShownItemContexts[index].shownInterfaceWindows.contains(where: { $0.windowID == window.windowID }) {
            tempShownItemContexts[index].shownInterfaceWindows.append(window)
        }
    }

    private func currentReturnDestination(for context: TempShownItemContext, items: [MenuBarItem]) -> MoveDestination? {
        switch context.returnDestination {
        case .leftOfItem(let target):
            if let current = items.first(where: { $0.windowID == target.windowID }) { return .leftOfItem(current) }
        case .rightOfItem(let target):
            if let current = items.first(where: { $0.windowID == target.windowID }) { return .rightOfItem(current) }
        }
        if let position=context.originalWindowOrder.firstIndex(of:context.windowID) {
            for id in context.originalWindowOrder.dropFirst(position+1) {
                if let current=items.first(where:{ $0.windowID == id }) { return .leftOfItem(current) }
            }
            for id in context.originalWindowOrder.prefix(position).reversed() {
                if let current=items.first(where:{ $0.windowID == id }) { return .rightOfItem(current) }
            }
        }
        let boundaryInfo: MenuBarItemInfo = context.returnSection == .alwaysHidden ? .alwaysHiddenControlItem : .hiddenControlItem
        guard let boundary = items.first(where: { $0.info == boundaryInfo }) ?? items.first(where: { $0.info == .hiddenControlItem }) else { return nil }
        return context.returnSection == .visible ? .rightOfItem(boundary) : .leftOfItem(boundary)
    }

    private func originalPositionEvidence(_ context: TempShownItemContext, items: [MenuBarItem]) -> NativeReturnEvidence.Assessment {
        NativeReturnEvidence.assess(windowID:context.windowID,originalFrame:context.originalFrame,
            originalOrder:context.originalWindowOrder,currentFrame:Bridging.getWindowFrame(for:context.windowID),
            currentOrder:items.map(\.windowID))
    }
    private func traceNativeRestore(_ phase: String, context: TempShownItemContext, items: [MenuBarItem], error: Error? = nil) {
        let args=ProcessInfo.processInfo.arguments
        guard let index=args.firstIndex(of:"--diagnostics-path"),args.indices.contains(index+1) else { return }
        let evidence=originalPositionEvidence(context,items:items)
        let current=items.first { $0.windowID == context.windowID }
        var payload:[String:Any]=[
            "phase":phase,"timestamp":Date().timeIntervalSince1970,"windowID":context.windowID,"key":context.info.description,
            "originalFrame":context.originalFrame.map(NSStringFromRect) ?? "unknown",
            "actualFrame":Bridging.getWindowFrame(for:context.windowID).map(NSStringFromRect) ?? "missing",
            "originalOrder":context.originalWindowOrder,"actualOrder":NativeReturnEvidence.unique(items.map(\.windowID)),
            "originalOnScreen":context.originalOnScreen ?? false,"actualOnScreen":current?.isOnScreen ?? false,
            "sameMenuBand":evidence.sameMenuBand,"frameMatches":evidence.frameMatches,"orderMatches":evidence.orderMatches,
            "hasSurvivingNeighbor":evidence.hasSurvivingNeighbor,"confirmedOriginal":evidence.confirmsOriginalPosition,
            "movementCheckpoint":context.movementCheckpointID?.uuidString ?? "","remainingBudget":nativeLifecycle.remainingTime.isFinite ? nativeLifecycle.remainingTime : -1
        ]
        if let error { payload["error"]=error.localizedDescription }
        guard let json=try? JSONSerialization.data(withJSONObject:payload,options:.sortedKeys) else { return }
        let url=URL(fileURLWithPath:args[index+1]).deletingPathExtension().appendingPathExtension("native-restore.jsonl")
        var line=json;line.append(10)
        if !FileManager.default.fileExists(atPath:url.path) { FileManager.default.createFile(atPath:url.path,contents:line) }
        else if let handle=try? FileHandle(forWritingTo:url) { try? handle.seekToEnd();try? handle.write(contentsOf:line);try? handle.close() }
    }

    /// Rehides all temporarily shown items.
    ///
    /// If an item is currently showing its interface, this method waits for the
    /// interface to close before hiding the items.
    func rehideTempShownItems() async {
        guard !nativeLifecycle.isStopping else { return }
        guard !isMovingItem, !isOpeningInterface else { runTempShownItemTimer(for:1); return }
        itemMoveCount += 1
        defer { itemMoveCount -= 1; Task { await self.refreshItems() } }
        guard !tempShownItemContexts.isEmpty else { return }
        guard !isMouseButtonDown else { runTempShownItemTimer(for:3); return }
        guard tempShownItemContexts.contains(where:{ $0.movementCheckpointID == nil || $0.movementRollbackRequested }) else {
            tempShownItemsTimer?.invalidate();tempShownItemsTimer=nil;return
        }
        for index in tempShownItemContexts.indices { refreshShownInterfaces(at:index) }
        let eligible=tempShownItemContexts.filter { $0.movementCheckpointID == nil || $0.movementRollbackRequested }
        guard !eligible.contains(where:{ $0.isShowingInterface }) else {
            runTempShownItemTimer(for:1); return
        }
        let cursorLease = beginCursorLease(returnTo:nil)
        defer { endCursorLease(cursorLease) }
        // Keep contexts in the persistent array while awaiting a move. A forced
        // termination can then still restore a return operation already in flight.
        for context in eligible.reversed() {
            if nativeLifecycle.isStopping { return }
            let items = MenuBarItem.getMenuBarItems(onScreenOnly:false,activeSpaceOnly:true)
            traceNativeRestore("normal-return-start",context:context,items:items)
            guard let item = items.first(where:{ $0.windowID == context.windowID }) else {
                traceNativeRestore("normal-return-source-removed",context:context,items:items)
                tempShownItemContexts.removeAll { $0.windowID == context.windowID }; continue
            }
            if originalPositionEvidence(context,items:items).confirmsOriginalPosition {
                traceNativeRestore("normal-return-already-original",context:context,items:items)
                tempShownItemContexts.removeAll { $0.windowID == context.windowID };continue
            }
            do {
                guard let destination = currentReturnDestination(for:context,items:items) else {
                    throw EventError(code:.invalidItem,item:item)
                }
                traceNativeRestore("normal-return-native-attempt",context:context,items:items)
                try await slowMove(item:item,to:destination,timeout:.seconds(1))
                let after=MenuBarItem.getMenuBarItems(onScreenOnly:false,activeSpaceOnly:true)
                guard originalPositionEvidence(context,items:after).confirmsOriginalPosition ||
                      (try? itemHasCorrectPosition(item:item,for:destination)) == true else {
                    throw EventError(code:.couldNotComplete,item:item)
                }
                traceNativeRestore("normal-return-confirmed",context:context,items:after)
                tempShownItemContexts.removeAll { $0.windowID == context.windowID }
                LayoutDiagnostics.appendText("[rehide] wid=\(context.windowID) returned to original section")
            } catch {
                if nativeLifecycle.isStopping { return }
                let after=MenuBarItem.getMenuBarItems(onScreenOnly:false,activeSpaceOnly:true)
                if originalPositionEvidence(context,items:after).confirmsOriginalPosition {
                    traceNativeRestore("normal-return-error-but-original",context:context,items:after,error:error)
                    tempShownItemContexts.removeAll { $0.windowID == context.windowID };continue
                }
                traceNativeRestore("normal-return-unconfirmed",context:context,items:after,error:error)
                Logger.itemManager.error("Failed to rehide \(item.logString) (error: \(error))")
            }
        }
        if tempShownItemContexts.isEmpty { tempShownItemsTimer?.invalidate(); tempShownItemsTimer=nil }
        else { runTempShownItemTimer(for:3) }
    }

    /// Register before a permanent pin/unpin move. Only commit after the
    /// physical target and its persisted preference are both verified.
    func registerMovementRollback(for item: MenuBarItem) throws -> NativeMovementCheckpoint {
        guard !isShuttingDown, let latest=MenuBarItem(windowID:item.windowID) else { throw CancellationError() }
        if let index=tempShownItemContexts.firstIndex(where:{ $0.windowID == item.windowID }) {
            if let id=tempShownItemContexts[index].movementCheckpointID { return NativeMovementCheckpoint(id:id,windowID:item.windowID) }
            let id=UUID();tempShownItemContexts[index].movementCheckpointID=id
            return NativeMovementCheckpoint(id:id,windowID:item.windowID)
        }
        let items=MenuBarItem.getMenuBarItems(onScreenOnly:false,activeSpaceOnly:true)
        guard let destination=getReturnDestination(for:latest,in:items) else { throw EventError(code:.invalidItem,item:item) }
        let divider=items.first { $0.info == .hiddenControlItem }
        let section=itemCache.section(for:latest) ?? (divider.map { latest.frame.maxX <= $0.frame.minX } == true ? .hidden : .visible)
        let id=UUID()
        let band=CGRect(x:latest.frame.minX,y:latest.frame.minY,width:latest.frame.width,height:latest.frame.height)
        tempShownItemContexts.append(TempShownItemContext(windowID:latest.windowID,info:latest.info,
            returnDestination:destination,returnSection:section,sourcePID:latest.sourcePID,menuBand:band,movementCheckpointID:id,
            originalFrame:Bridging.getWindowFrame(for:latest.windowID) ?? latest.frame,
            originalWindowOrder:NativeReturnEvidence.unique(items.map(\.windowID)),originalOnScreen:latest.isOnScreen))
        return NativeMovementCheckpoint(id:id,windowID:latest.windowID)
    }
    func canCommitMovement(_ checkpoint: NativeMovementCheckpoint) -> Bool {
        !isShuttingDown && tempShownItemContexts.contains { $0.windowID == checkpoint.windowID && $0.movementCheckpointID == checkpoint.id }
    }
    @discardableResult func commitMovement(_ checkpoint: NativeMovementCheckpoint) -> Bool {
        guard canCommitMovement(checkpoint) else { return false }
        tempShownItemContexts.removeAll { $0.windowID == checkpoint.windowID && $0.movementCheckpointID == checkpoint.id }
        if tempShownItemContexts.isEmpty { tempShownItemsTimer?.invalidate();tempShownItemsTimer=nil }
        Task { await self.refreshItems() }
        return true
    }
    func requestMovementRollback(_ checkpoint: NativeMovementCheckpoint) {
        guard !isShuttingDown,let index=tempShownItemContexts.firstIndex(where:{ $0.movementCheckpointID == checkpoint.id }) else { return }
        tempShownItemContexts[index].movementRollbackRequested=true
        runTempShownItemTimer(for:1)
    }

    /// Stops new native actions and restores this app's temporary item moves.
    /// The shutdown budget is capped at 3s; a pending event acknowledgement can
    /// add at most its 250ms cancellation cleanup (synchronous OS calls excluded).
    func prepareForTermination(timeout: TimeInterval = 3) async -> NativeRestorationReport {
        if let terminationTask { return await terminationTask.value }
        let budget = min(3,max(0.25,timeout))
        let token = nativeLifecycle.beginTermination(budget:budget)
        cancellables.removeAll(); tempShownItemsTimer?.invalidate(); tempShownItemsTimer=nil
        MenuBarSourceResolver.stop()
        releaseSyntheticPress()
        let task = Task { await self.finishNativeTermination(token:token) }
        terminationTask=task
        return await task.value
    }

    /// force=true is the irreversible shutdown path; normal restoration preserves
    /// active original menus and may schedule a later retry instead of blocking.
    func restoreTemporaryItems(force: Bool = false, timeout: TimeInterval = 3) async -> NativeRestorationReport {
        if force { return await prepareForTermination(timeout:timeout) }
        let start=ProcessInfo.processInfo.systemUptime, count=tempShownItemContexts.count
        await rehideTempShownItems()
        return NativeRestorationReport(restoredCount:max(0,count-tempShownItemContexts.count),
            remainingWindowIDs:tempShownItemContexts.map(\.windowID),elapsed:ProcessInfo.processInfo.systemUptime-start)
    }

    private func finishNativeTermination(token: NativeInteractionLifecycle.Token) async -> NativeRestorationReport {
        let start=ProcessInfo.processInfo.systemUptime, originalCount=tempShownItemContexts.count
        // Old event callbacks see an expired generation and cannot start a new
        // pickup. Let their bounded acknowledgements unwind before restoring.
        let settleDeadline=start+min(0.6,nativeLifecycle.remainingTime)
        while activeNativeWorkCount>0 && ProcessInfo.processInfo.systemUptime<settleDeadline {
            try? await Task.sleep(for:.milliseconds(10))
        }
        releaseSyntheticPress(); releaseCursorLeases()
        for index in tempShownItemContexts.indices { refreshShownInterfaces(at:index) }
        for context in tempShownItemContexts.reversed() {
            guard nativeLifecycle.accepts(token), nativeLifecycle.remainingTime>0.05 else { break }
            dismissOriginalInterface(context)
            if context.isShowingInterface && nativeLifecycle.remainingTime>0.08 { try? await Task.sleep(for:.milliseconds(80)) }
            let items=MenuBarItem.getMenuBarItems(onScreenOnly:false,activeSpaceOnly:true)
            traceNativeRestore("termination-return-start",context:context,items:items)
            guard let item=items.first(where:{ $0.windowID == context.windowID }) else {
                traceNativeRestore("termination-return-source-removed",context:context,items:items)
                tempShownItemContexts.removeAll { $0.windowID == context.windowID }; continue
            }
            if originalPositionEvidence(context,items:items).confirmsOriginalPosition {
                traceNativeRestore("termination-return-already-original",context:context,items:items)
                tempShownItemContexts.removeAll { $0.windowID == context.windowID };continue
            }
            guard let destination=currentReturnDestination(for:context,items:items) else {
                traceNativeRestore("termination-return-no-destination",context:context,items:items);continue
            }
            let cursorLease=beginCursorLease(returnTo:MouseCursor.locationCoreGraphics)
            do {
                if (try? itemHasCorrectPosition(item:item,for:destination)) != true {
                    // One attempt per item, no unbounded modifier/menu waits or
                    // wake-up retries on the termination path.
                    traceNativeRestore("termination-return-native-attempt",context:context,items:items)
                    try await moveItemWithoutRestoringMouseLocation(item,to:destination,token:token)
                }
                let after=MenuBarItem.getMenuBarItems(onScreenOnly:false,activeSpaceOnly:true)
                if originalPositionEvidence(context,items:after).confirmsOriginalPosition ||
                   (try? itemHasCorrectPosition(item:item,for:destination)) == true {
                    traceNativeRestore("termination-return-confirmed",context:context,items:after)
                    tempShownItemContexts.removeAll { $0.windowID == context.windowID }
                } else { traceNativeRestore("termination-return-unconfirmed",context:context,items:after) }
            } catch {
                let after=MenuBarItem.getMenuBarItems(onScreenOnly:false,activeSpaceOnly:true)
                if originalPositionEvidence(context,items:after).confirmsOriginalPosition {
                    traceNativeRestore("termination-return-error-but-original",context:context,items:after,error:error)
                    tempShownItemContexts.removeAll { $0.windowID == context.windowID }
                } else {
                    traceNativeRestore("termination-return-unconfirmed",context:context,items:after,error:error)
                    Logger.itemManager.warning("Termination return failed for \(item.logString): \(error)")
                }
            }
            endCursorLease(cursorLease)
        }
        if !tempShownItemContexts.isEmpty {
            let remainingItems=MenuBarItem.getMenuBarItems(onScreenOnly:false,activeSpaceOnly:true)
            for context in tempShownItemContexts {
                traceNativeRestore("termination-return-remaining",context:context,items:remainingItems)
            }
        }
        nativeLifecycle.finishTermination()
        releaseSyntheticPress(); releaseCursorLeases()
        return NativeRestorationReport(restoredCount:max(0,originalCount-tempShownItemContexts.count),
            remainingWindowIDs:tempShownItemContexts.map(\.windowID),elapsed:ProcessInfo.processInfo.systemUptime-start)
    }

    private func dismissOriginalInterface(_ context: TempShownItemContext) {
        for observed in context.shownInterfaceWindows {
            guard let window=WindowInfo(windowID:observed.windowID),window.isOnScreen,
                  NativeInteractionPolicy.retainsTemporaryItem(layer:window.layer,frame:window.frame,
                    popupLayer:Int(CGWindowLevelForKey(.popUpMenuWindow)),menuBand:context.menuBand),
                  let down=CGEvent(keyboardEventSource:nil,virtualKey:53,keyDown:true),
                  let up=CGEvent(keyboardEventSource:nil,virtualKey:53,keyDown:false) else { continue }
            for event in [down,up] {
                event.flags=[]
                event.setIntegerValueField(.eventTargetUnixProcessID,value:Int64(window.ownerPID))
                event.setIntegerValueField(CGEventField(rawValue:0x33)!,value:Int64(window.windowID))
                event.postToPid(window.ownerPID)
            }
        }
    }

    /// Removes a temporarily shown item from the cache.
    ///
    /// This ensures that the item will _not_ be returned to its previous location.
    func removeTempShownItemFromCache(with windowID: CGWindowID) {
        tempShownItemContexts.removeAll { $0.windowID == windowID && $0.movementCheckpointID == nil }
    }
}

// MARK: - Arrange Items

extension MenuBarItemManager {
    /// Enforces the order of the given control items, ensuring that the always-hidden
    /// control item stays to the left of the hidden control item.
    ///
    /// - Parameters:
    ///   - hiddenControlItem: A menu bar item that represents the control item for the
    ///     hidden section.
    ///   - alwaysHiddenControlItem: A menu bar item that represents the control item
    ///     for the always-hidden section.
    func enforceControlItemOrder(hiddenControlItem: MenuBarItem, alwaysHiddenControlItem: MenuBarItem) async throws {
        guard !isMouseButtonDown else {
            Logger.itemManager.debug("Mouse button is down, so will not enforce control item order")
            return
        }
        guard !mouseHasRecentlyMoved else {
            Logger.itemManager.debug("Mouse has recently moved, so will not enforce control item order")
            return
        }
        if hiddenControlItem.frame.maxX <= alwaysHiddenControlItem.frame.minX {
            Logger.itemManager.info("Arranging menu bar items")
            try await slowMove(item: alwaysHiddenControlItem, to: .leftOfItem(hiddenControlItem))
        }
    }
}

// MARK: - Menu Bar Item Event Helper Types

/// Button states for menu bar item events.
private enum MenuBarItemEventButtonState {
    case leftMouseDown
    case leftMouseUp
    case rightMouseDown
    case rightMouseUp
    case otherMouseDown
    case otherMouseUp
}

/// Event types for menu bar item events.
private enum MenuBarItemEventType {
    /// The event type for moving a menu bar item.
    case move(MenuBarItemEventButtonState)

    /// The event type for clicking a menu bar item.
    case click(MenuBarItemEventButtonState)

    /// The button state of this event type.
    var buttonState: MenuBarItemEventButtonState {
        switch self {
        case .move(let state), .click(let state): state
        }
    }

    /// This event type's equivalent CGEventType.
    var cgEventType: CGEventType {
        switch buttonState {
        case .leftMouseDown: .leftMouseDown
        case .leftMouseUp: .leftMouseUp
        case .rightMouseDown: .rightMouseDown
        case .rightMouseUp: .rightMouseUp
        case .otherMouseDown: .otherMouseDown
        case .otherMouseUp: .otherMouseUp
        }
    }

    /// The event flags for this event type.
    var cgEventFlags: CGEventFlags {
        switch self {
        case .move(.leftMouseDown): .maskCommand
        case .move, .click: []
        }
    }

    /// The mouse button for this event type.
    var mouseButton: CGMouseButton {
        switch buttonState {
        case .leftMouseDown, .leftMouseUp: .left
        case .rightMouseDown, .rightMouseUp: .right
        case .otherMouseDown, .otherMouseUp: .center
        }
    }
}

// MARK: - CGEventField Helpers

private extension CGEventField {
    /// Key to access a field that contains the event's window identifier.
    static let windowID = CGEventField(rawValue: 0x33)! // swiftlint:disable:this force_unwrapping

    /// An array of integer event fields that can be used to compare menu bar item events.
    static let menuBarItemEventFields: [CGEventField] = [
        .eventSourceUserData,
        .mouseEventWindowUnderMousePointer,
        .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
        .windowID,
    ]
}

// MARK: - CGEventFilterMask Helpers

private extension CGEventFilterMask {
    /// Specifies that all events should be permitted during event suppression states.
    static let permitAllEvents: CGEventFilterMask = [
        .permitLocalMouseEvents,
        .permitLocalKeyboardEvents,
        .permitSystemDefinedEvents,
    ]
}

// MARK: - CGEventType Helpers

private extension CGEventType {
    /// A string to use for logging purposes.
    var logString: String {
        switch self {
        case .null: "null event"
        case .leftMouseDown: "leftMouseDown event"
        case .leftMouseUp: "leftMouseUp event"
        case .rightMouseDown: "rightMouseDown event"
        case .rightMouseUp: "rightMouseUp event"
        case .mouseMoved: "mouseMoved event"
        case .leftMouseDragged: "leftMouseDragged event"
        case .rightMouseDragged: "rightMouseDragged event"
        case .keyDown: "keyDown event"
        case .keyUp: "keyUp event"
        case .flagsChanged: "flagsChanged event"
        case .scrollWheel: "scrollWheel event"
        case .tabletPointer: "tabletPointer event"
        case .tabletProximity: "tabletProximity event"
        case .otherMouseDown: "otherMouseDown event"
        case .otherMouseUp: "otherMouseUp event"
        case .otherMouseDragged: "otherMouseDragged event"
        case .tapDisabledByTimeout: "tapDisabledByTimeout event"
        case .tapDisabledByUserInput: "tapDisabledByUserInput event"
        @unknown default: "unknown event"
        }
    }
}

// MARK: - CGMouseButton Helpers

private extension CGMouseButton {
    /// A string to use for logging purposes.
    var logString: String {
        switch self {
        case .left: "left mouse button"
        case .right: "right mouse button"
        case .center: "center mouse button"
        @unknown default: "unknown mouse button"
        }
    }

    /// The equivalent down and up button states for menu bar item click events.
    var buttonStates: (down: MenuBarItemEventButtonState, up: MenuBarItemEventButtonState) {
        switch self {
        case .left: (.leftMouseDown, .leftMouseUp)
        case .right: (.rightMouseDown, .rightMouseUp)
        default: (.otherMouseDown, .otherMouseUp)
        }
    }
}

// MARK: - CGEvent Constructor

private extension CGEvent {
    /// Returns an event that can be sent to the given menu bar item.
    ///
    /// - Parameters:
    ///   - type: The type of the event.
    ///   - location: The location of the event. Does not need to be within the bounds of the item.
    ///   - item: The target item of the event.
    ///   - pid: The target process identifier of the event. Does not need to be the item's `ownerPID`.
    ///   - source: The source of the event.
    class func menuBarItemEvent(type: MenuBarItemEventType, location: CGPoint, item: MenuBarItem, pid: pid_t, source: CGEventSource) -> CGEvent? {
        let mouseType = type.cgEventType
        let mouseButton = type.mouseButton

        guard let event = CGEvent(mouseEventSource: source, mouseType: mouseType, mouseCursorPosition: location, mouseButton: mouseButton) else {
            return nil
        }

        event.flags = type.cgEventFlags

        let targetPID = Int64(pid)
        let userData = Int64(truncatingIfNeeded: Int(bitPattern: ObjectIdentifier(event)))
        let windowID = Int64(item.windowID)

        event.setIntegerValueField(.eventTargetUnixProcessID, value: targetPID)
        event.setIntegerValueField(.eventSourceUserData, value: userData)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: windowID)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: windowID)
        // The private window field is a movement hint. For hosted plain clicks
        // it is not the client's remote NSWindow number and must stay unset.
        if case .move = type { event.setIntegerValueField(.windowID,value:windowID) }

        if case .click = type {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }

        return event
    }
}

// MARK: - Logger

private extension Logger {
    /// The logger to use for the menu bar item manager.
    static let itemManager = Logger(category: "MenuBarItemManager")
}
