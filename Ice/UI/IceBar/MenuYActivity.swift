import AppKit
import Combine

@MainActor final class MenuYActivity: ObservableObject {
    @Published private(set) var changed = Set<String>()
    @Published private(set) var unread = [String: Int]()
    @Published private(set) var unreadConfirmedAt = [String: TimeInterval]()
    @Published private(set) var unreadStale = Set<String>()
    private var hintHistory = MenuYHintHistory()
    private var signatures = [String: Data]()
    private var subscriptions = Set<AnyCancellable>()
    private weak var appState: AppState?
    private let hintsQueue = DispatchQueue(label: "io.novarock.MacMenuY.indicator-hints", qos: .utility)
    private var hintsRunning = false
    private var hintGroupOffset = 0

    var changedAppCount: Int {
        guard let appState, appState.preferences.activityEnabled else { return 0 }
        return Set(appState.itemManager.itemCache.allItems.filter {
            changed.contains($0.info.description) && shouldMonitor($0, preferences: appState.preferences)
        }.map { $0.info.namespace.rawValue }).count
    }
    var unreadCount: Int {
        guard let appState else { return 0 }
        var perApp = [String: Int]()
        for item in appState.itemManager.itemCache.allItems {
            perApp[item.info.namespace.rawValue] = max(perApp[item.info.namespace.rawValue] ?? 0, unread[item.info.description] ?? 0)
        }
        return perApp.values.reduce(0,+)
    }
    init(appState: AppState) { self.appState = appState }
    func performSetup() {
        guard subscriptions.isEmpty, let appState else { return }
        appState.imageCache.$images.receive(on: DispatchQueue.main).sink { [weak self] images in self?.observe(images) }
            .store(in: &subscriptions)
        appState.preferences.objectWillChange.debounce(for: 0.02, scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.reconcilePolicy() }.store(in: &subscriptions)
        appState.itemManager.$itemCache.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.prune() }
            .store(in: &subscriptions)
        DistributedNotificationCenter.default().publisher(for: NSNotification.Name("AppleInterfaceThemeChangedNotification"))
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.signatures.removeAll() }.store(in: &subscriptions)
        Timer.publish(every: 5, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.refreshHints() }
            .store(in: &subscriptions)
        refreshHints()
    }
    func acknowledge(_ item: MenuBarItem) { changed.remove(item.info.description) }
    func acknowledgeAll() { changed.removeAll() }
    func hasActivity(_ item: MenuBarItem) -> Bool {
        let visibleChange = appState.map { $0.preferences.activityEnabled && shouldMonitor(item, preferences: $0.preferences) && changed.contains(item.info.description) } ?? false
        return visibleChange || (unread[item.info.description] ?? 0) > 0
    }
    private func shouldMonitor(_ item: MenuBarItem, preferences: MenuYPreferences) -> Bool {
        item.info.namespace != .ice && !item.info.namespace.rawValue.hasPrefix("com.apple.") &&
            !preferences.ignoredApps.contains(item.info.namespace.rawValue)
    }
    private func reconcilePolicy() {
        guard let appState else { return }
        if !appState.preferences.activityEnabled { changed.removeAll(); return }
        let allowed = Set(appState.itemManager.itemCache.allItems.filter {
            shouldMonitor($0, preferences: appState.preferences)
        }.map { $0.info.description })
        changed.formIntersection(allowed)
    }
    private func prune() {
        guard let appState else { return }
        let keys = Set(appState.itemManager.itemCache.allItems.map { $0.info.description })
        signatures = signatures.filter { keys.contains($0.key) }
        changed.formIntersection(keys)
        hintHistory.prune(activeKeys: keys)
        publishHints()
    }
    private func observe(_ images: [CGWindowID: CGImage]) {
        guard let appState else { return }
        let moving = appState.itemManager.isMovingItem || appState.itemManager.itemHasRecentlyMoved
        for item in appState.itemManager.itemCache.allItems where item.info.namespace != .ice {
            guard let image = images[item.windowID], let digest = MenuYVisualFingerprint.digest(image) else { continue }
            let key = item.info.description
            if let old = signatures[key], old != digest, !moving,
               appState.preferences.activityEnabled, shouldMonitor(item, preferences: appState.preferences) { changed.insert(key) }
            // A move/theme redraw becomes the new baseline, not a notification.
            signatures[key] = digest
        }
        prune()
    }

    private struct HintTarget {
        let key: String
        let pid: pid_t
        let windowID: CGWindowID
    }
    private struct HintChild {
        let element: AXUIElement
        let frame: CGRect?
    }
    private func publishHints() {
        unread = hintHistory.values
        unreadConfirmedAt = hintHistory.confirmedAt
        unreadStale = hintHistory.stale
    }
    private struct HintChildren {
        let items: [HintChild]
        let complete: Bool
    }
    private func refreshHints() {
        guard !hintsRunning, let appState else { return }
        let activeKeys = Set(appState.itemManager.itemCache.allItems.map { $0.info.description })
        guard AXIsProcessTrusted() else {
            hintHistory.apply([:], activeKeys: activeKeys, now: Date().timeIntervalSince1970)
            publishHints()
            return
        }
        let items = appState.itemManager.itemCache.allItems.compactMap { item -> HintTarget? in
            guard let source = MenuBarSourceResolver.lookup(item.windowID), item.info.namespace != .ice else { return nil }
            return HintTarget(key: item.info.description, pid: source.pid, windowID: item.windowID)
        }
        // Rotate source apps between bounded scans so an unresponsive app cannot
        // repeatedly consume the budget before later apps are reached.
        var seenPIDs = Set<pid_t>()
        let pids = items.compactMap { seenPIDs.insert($0.pid).inserted ? $0.pid : nil }
        let groups = Dictionary(grouping: items, by: \.pid)
        let start = pids.isEmpty ? 0 : hintGroupOffset % pids.count
        let scanPIDs = Array(pids.dropFirst(start)) + Array(pids.prefix(start))
        let scanItems = scanPIDs.flatMap { groups[$0] ?? [] }
        hintGroupOffset = pids.isEmpty ? 0 : (start+1) % pids.count
        hintsRunning = true
        hintsQueue.async { [weak self] in
            var result = [String: MenuYHintObservation](), childCache = [pid_t: HintChildren]()
            let started = ProcessInfo.processInfo.systemUptime
            for item in scanItems {
                // No unresponsive app may hold the monitor indefinitely.
                guard ProcessInfo.processInfo.systemUptime - started < 3 else { break }
                if childCache[item.pid] == nil {
                    childCache[item.pid] = Self.children(pid: item.pid)
                }
                guard let snapshot = childCache[item.pid], snapshot.complete,
                      let before = Bridging.getWindowFrame(for: item.windowID),
                      let index = MenuYHintGeometry.bestIndex(window: before, children: snapshot.items.map(\.frame)) else {
                    result[item.key] = .unavailable; continue
                }
                let element = snapshot.items[index].element
                let attributes = ["AXDescription", "AXHelp", "AXTitle"].map { Self.hintAttribute(element, $0) }
                guard attributes.allSatisfy(\.complete), Bridging.getWindowFrame(for: item.windowID) == before else {
                    result[item.key] = .unavailable; continue
                }
                // Do not trust a cached source.slot: AX children can reorder.
                let text = attributes.compactMap { $0.text }.joined(separator: " ")
                result[item.key] = MenuYHintObservation.completed(text: text)
            }
            Task { @MainActor [weak self] in
                guard let self, let appState = self.appState else { return }
                let keys = Set(appState.itemManager.itemCache.allItems.map { $0.info.description })
                self.hintHistory.apply(result, activeKeys: keys, now: Date().timeIntervalSince1970)
                self.publishHints()
                self.hintsRunning = false
            }
        }
    }
    nonisolated private static func children(pid: pid_t) -> HintChildren {
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.08)
        guard let rawBar = attribute(root, "AXExtrasMenuBar"), CFGetTypeID(rawBar) == AXUIElementGetTypeID() else { return HintChildren(items: [], complete: false) }
        let bar = rawBar as! AXUIElement; AXUIElementSetMessagingTimeout(bar, 0.08)
        guard let children = attribute(bar, "AXChildren") as? [AXUIElement] else { return HintChildren(items: [], complete: false) }
        let started = ProcessInfo.processInfo.systemUptime
        var result = [HintChild]()
        for child in children {
            guard ProcessInfo.processInfo.systemUptime - started < 0.5 else { return HintChildren(items: result, complete: false) }
            AXUIElementSetMessagingTimeout(child, 0.08)
            guard let bounds = frame(child) else { return HintChildren(items: result, complete: false) }
            result.append(HintChild(element: child, frame: bounds))
        }
        return HintChildren(items: result, complete: true)
    }
    nonisolated private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = attribute(element, "AXPosition"), let s = attribute(element, "AXSize"),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
    private struct HintAttribute {
        let text: String?
        let complete: Bool
    }
    nonisolated private static func hintAttribute(_ element: AXUIElement, _ name: String) -> HintAttribute {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        switch error {
        case .success: return HintAttribute(text: value as? String, complete: true)
        case .attributeUnsupported, .noValue: return HintAttribute(text: nil, complete: true)
        default: return HintAttribute(text: nil, complete: false)
        }
    }
    nonisolated private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
