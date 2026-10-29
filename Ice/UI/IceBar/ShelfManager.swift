import Cocoa
import Combine

@MainActor
final class ShelfManager: ObservableObject {
    @Published var message: String?
    @Published private(set) var isBusy = false
    private(set) var lastNativeAction = ""
    @Published private(set) var isEnabled = true
    @Published private(set) var pinned: Set<String>
    private weak var appState: AppState?
    private var subscriptions = Set<AnyCancellable>()
    private var reconciledWindows = Set<CGWindowID>()
    private let preferencesKey = "MacMenuY.PinnedItems.v1"

    init(appState: AppState) {
        self.appState = appState
        self.pinned = Set(UserDefaults.standard.stringArray(forKey: preferencesKey) ?? [])
    }

    func performSetup() {
        guard let appState else { return }
        appState.itemManager.$itemCache
            .debounce(for: 0.7, scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.reconcilePins(); self.writeDiagnostics() }
            }.store(in: &subscriptions)
        Timer.publish(every: 3, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.writeDiagnostics() }
            .store(in: &subscriptions)
    }

    static func key(_ item: MenuBarItem) -> String { item.info.description }

    func isPinned(_ item: MenuBarItem) -> Bool {
        guard item.isMovable && item.canBeHidden else { return true }
        if !isEnabled { return pinned.contains(Self.key(item)) }
        return appState?.itemManager.itemCache.section(for:item) == .visible
    }

    func toggle(_ item: MenuBarItem) async {
        guard !isBusy,item.isMovable,item.canBeHidden else { return }
        let targetPinned = !isPinned(item)
        isBusy = true
        message = nil
        defer { isBusy = false; writeDiagnostics() }
        var checkpoint: MenuBarItemManager.NativeMovementCheckpoint?
        do {
            guard let appState else { throw ShelfError.unavailable }
            let registered=try appState.itemManager.registerMovementRollback(for:item)
            checkpoint=registered
            try await move(item,pinned:targetPinned)
            guard appState.itemManager.canCommitMovement(registered) else { throw ShelfError.unavailable }
            if targetPinned { pinned.insert(Self.key(item)) }
            else { pinned.remove(Self.key(item)) }
            UserDefaults.standard.set(pinned.sorted(), forKey: preferencesKey)
            _=appState.itemManager.commitMovement(registered)
            reconciledWindows.insert(item.windowID)
        } catch {
            if let checkpoint { appState?.itemManager.requestMovementRollback(checkpoint) }
            message = "无法\(targetPinned ? "固定" : "收回") \(item.displayName)：\(error.localizedDescription)"
        }
    }

    private func move(_ item: MenuBarItem, pinned: Bool) async throws {
        guard let appState, AXIsProcessTrusted(),
              let dividerID = appState.menuBarManager.section(withName: .hidden)?.controlItem.windowID,
              let divider = MenuBarItem(windowID: dividerID),
              let latest = MenuBarItem(windowID: item.windowID)
        else { throw ShelfError.unavailable }
        appState.itemManager.removeTempShownItemFromCache(with: item.windowID)
        var operationError: Error?
        do {
            try await appState.itemManager.slowMove(
                item: latest, to: pinned ? .rightOfItem(divider) : .leftOfItem(divider), timeout: .seconds(2))
        } catch { operationError = error }
        await appState.itemManager.refreshItems()
        // Verify the actual WindowServer frames before committing the preference.
        guard let current = Bridging.getWindowFrame(for: item.windowID),
              let boundary = Bridging.getWindowFrame(for: dividerID),
              pinned ? current.minX >= boundary.maxX - 1 : current.maxX <= boundary.minX + 1
        else { throw operationError ?? ShelfError.positionNotVerified }
    }

    private func reconcilePins() async {
        guard !isBusy,isEnabled,let appState else { return }
        let items=appState.itemManager.itemCache.allItems
        let migration=MenuBarItem.identityMigrationMap(for:items)
        var migrated=pinned
        for (old,new) in migration where migrated.contains(old) { migrated.remove(old);migrated.insert(new) }
        if migrated != pinned { pinned=migrated;UserDefaults.standard.set(pinned.sorted(),forKey:preferencesKey) }
        appState.preferences.migrateIdentityKeys(migration)
        let candidates=items.filter {
            $0.info.namespace != .ice && $0.isMovable && $0.canBeHidden &&
            pinned.contains(Self.key($0)) && !reconciledWindows.contains($0.windowID)
        }
        guard !candidates.isEmpty else { return }
        isBusy=true
        defer { isBusy=false }
        for item in candidates {
            var checkpoint: MenuBarItemManager.NativeMovementCheckpoint?
            do {
                if !isPinned(item) {
                    let registered=try appState.itemManager.registerMovementRollback(for:item)
                    checkpoint=registered
                    try await move(item,pinned:true)
                    guard appState.itemManager.canCommitMovement(registered) else { throw ShelfError.unavailable }
                    _=appState.itemManager.commitMovement(registered)
                }
                reconciledWindows.insert(item.windowID)
            } catch {
                if let checkpoint { appState.itemManager.requestMovementRollback(checkpoint) }
                message="恢复固定项目 \(item.displayName) 失败，可以点击图钉重试。"
                reconciledWindows.insert(item.windowID)
            }
        }
    }

    func activate(_ item: MenuBarItem, button: CGMouseButton, modifiers: NSEvent.ModifierFlags, clickCount: Int,
                  closeShelf: Bool) async {
        guard !isBusy, let appState else { return }
        lastNativeAction="begin: \(item.info.description) button=\(button.rawValue)"
        isBusy = true; message = nil
        defer { isBusy = false; writeDiagnostics() }
        if closeShelf { appState.menuBarManager.iceBarPanel.close() }
        do {
            try await appState.itemManager.revealAndClick(item, mouseButton: button,
                modifiers: CGEventFlags(rawValue: UInt64(modifiers.intersection(.deviceIndependentFlagsMask).rawValue)),
                clickCount: clickCount)
            appState.preferences.used(item); appState.activity.acknowledge(item)
            lastNativeAction="completed: \(item.info.description)"
        } catch { lastNativeAction="failed: \(item.info.description) \(error.localizedDescription)"; message = "无法打开 \(item.displayName)：\(error.localizedDescription)" }
    }

    func toggleEnabled() {
        guard !isBusy, let appState else { return }
        isEnabled.toggle()
        appState.menuBarManager.section(withName: .hidden)?.controlItem.state = isEnabled ? .hideItems : .showItems
        appState.menuCover.update()
        writeDiagnostics()
    }

    func refresh() async {
        guard !isBusy, let appState else { return }
        await appState.itemManager.refreshItems()
        if ScreenCapture.cachedCheckPermissions(reset: true) {
            await appState.imageCache.updateCacheWithoutChecks(sections: MenuBarSection.Name.allCases)
        }
        writeDiagnostics()
    }

    /// Opt-in, local evidence for native integration verification. No IPC commands.
    func writeDiagnostics() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--diagnostics-path"), args.indices.contains(i + 1),
              let appState else { return }
        let items = appState.itemManager.itemCache.allItems.filter { $0.info.namespace != .ice && $0.owningApplication != .current }
        let panel = appState.menuBarManager.iceBarPanel
        let payload: [String: Any] = [
            "timestamp": Date().timeIntervalSince1970,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "accessibility": AXIsProcessTrusted(),
            "screenCapture": ScreenCapture.cachedCheckPermissions(reset: true),
            "enabled": isEnabled, "busy": isBusy, "lastNativeAction":lastNativeAction,
            "error": message ?? "", "pins": pinned.sorted(),
            "panelVisible": panel.isVisible, "dismissReason": panel.lastDismissReason,
            "panelFrame": NSStringFromRect(panel.frame),
            "layout": "horizontal", "opacity": panel.alphaValue, "covers": appState.menuCover.diagnostics(),
            "iconSize": appState.preferences.iconSize, "style": appState.preferences.style.rawValue,
            "sortMode": appState.preferences.sortMode.rawValue,
            "activityApps": appState.activity.changedAppCount, "unreadCount": appState.activity.unreadCount,
            "controls": appState.menuBarManager.sections.map { section -> [String: Any] in
                ["section": section.name.logString, "hostWindowID": section.controlItem.windowID ?? 0,
                 "proxyWindowNumber": section.controlItem.window?.windowNumber ?? 0]
            },
            "items": items.map { item -> [String: Any] in
                ["id": item.windowID, "key": Self.key(item), "name": item.displayName,
                 "pid": item.ownerPID, "section": appState.itemManager.itemCache.section(for: item)?.logString ?? "unknown",
                 "movable": item.isMovable, "hideable": item.canBeHidden, "pinned": self.isPinned(item),
                 "frame": NSStringFromRect(Bridging.getWindowFrame(for: item.windowID) ?? .zero),
                 "onScreen": MenuBarItem(windowID: item.windowID)?.isOnScreen ?? false,
                 "hasImage": appState.imageCache.images[item.windowID] != nil]
            }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: args[i + 1]), options: .atomic)
        }
    }
}

private enum ShelfError: LocalizedError {
    case unavailable, positionNotVerified
    var errorDescription: String? {
        switch self {
        case .unavailable: "图标已退出或辅助功能权限不可用。"
        case .positionNotVerified: "macOS 未完成移动，设置没有保存。"
        }
    }
}
