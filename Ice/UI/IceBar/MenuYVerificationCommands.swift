#if MENUY_VERIFY
import AppKit
import Darwin

/// Only an isolated macOS guest can enable this local test command surface.
/// It invokes the shipping native paths and reports real fixture callbacks;
/// transport completion is never treated as proof that an original menu ran.
@MainActor final class MenuYVerificationCommands {
    static let shared = MenuYVerificationCommands()
    private weak var appState: AppState?
    private var commandFile: URL?
    private var resultFolder: URL?
    private var fixtureFile: URL?
    private var timer: Timer?
    private var seenIDs = Set<String>()
    private var seenOrder = [String]()
    private var running = false

    static func setup(appState: AppState) { shared.start(appState: appState) }
    private func argument(_ flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }
    private static func sysctlString(_ key: String) -> String {
        var size: size_t = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0, size < 4096 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &bytes, &size, nil, 0) == 0 else { return "" }
        return String(cString: bytes)
    }
    private static var isVirtualMac: Bool {
        sysctlString("hw.model").lowercased().hasPrefix("virtualmac")
    }
    private func start(appState: AppState) {
        guard timer == nil, ProcessInfo.processInfo.arguments.contains("--verification-guest"), Self.isVirtualMac,
              let path = argument("--verification-command-file") else { return }
        self.appState = appState
        commandFile = URL(fileURLWithPath: path)
        resultFolder = URL(fileURLWithPath: argument("--verification-result-dir") ?? commandFile!.deletingLastPathComponent().appendingPathComponent("results").path, isDirectory: true)
        fixtureFile = argument("--verification-fixture-state").map { URL(fileURLWithPath: $0) }
        try? FileManager.default.createDirectory(at: resultFolder!, withIntermediateDirectories: true)
        let poll = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.consume() }
        }
        timer = poll; RunLoop.main.add(poll, forMode: .common)
        write(["status": "ready", "guestModel": Self.sysctlString("hw.model"), "state": snapshot()], id: "ready")
    }
    private func consume() {
        guard !running, let commandFile, let data = try? Data(contentsOf: commandFile), data.count <= 65536,
              let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = command["id"] as? String, validID(id), !seenIDs.contains(id) else { return }
        remember(id); running = true
        Task { @MainActor in
            let started = Date().timeIntervalSince1970
            var result: [String: Any] = ["id": id, "started": started, "guestModel": Self.sysctlString("hw.model")]
            do {
                guard let op = command["op"] as? String else { throw CommandError.invalid("Missing op") }
                result["op"] = op
                result["details"] = try await perform(op, command: command)
                result["status"] = "completed"
            } catch {
                result["status"] = "error"; result["error"] = error.localizedDescription
            }
            result["finished"] = Date().timeIntervalSince1970; result["state"] = snapshot()
            write(result, id: id); running = false
            if command["op"] as? String == "quit", result["status"] as? String == "completed" { timer?.invalidate();timer=nil;NSApp.terminate(nil) }
        }
    }
    private func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 80 && id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil && id != "ready"
    }
    private func remember(_ id: String) {
        seenIDs.insert(id); seenOrder.append(id)
        if seenOrder.count > 512 { seenIDs.remove(seenOrder.removeFirst()) }
    }
    private func fixtureItem(_ command: [String: Any]) throws -> MenuBarItem {
        guard let appState, let index = command["index"] as? Int, (1...1000).contains(index),
              let item = appState.itemManager.itemCache.allItems.first(where: {
                  $0.title == "Fixture-\(index)" && $0.info.namespace.rawValue == "io.novarock.MacMenuY.Fixture"
              }), let source = item.owningApplication,
              source.bundleIdentifier == "io.novarock.MacMenuY.Fixture" else { throw CommandError.invalid("Fixture index/source not available") }
        return item
    }
    private func wait(_ timeout: TimeInterval = 8, until condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + min(20, max(0, timeout))
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return condition()
    }
    private func perform(_ op: String, command: [String: Any]) async throws -> [String: Any] {
        guard let appState else { throw CommandError.invalid("App state missing") }
        switch op {
        case "snapshot", "refresh":
            await appState.shelfManager.refresh()
            return ["evidence": "read-only native state"]
        case "hover": return try await hoverScenario()
        case "preview":
            MenuYDebugHarness.holdShelf = true
            guard let screen = NSScreen.main else { throw CommandError.invalid("No guest display") }
            await appState.menuBarManager.iceBarPanel.show(section: .hidden, on: screen, activate: false)
            MenuYEvidence.capture(appState: appState)
            return ["visible": appState.menuBarManager.iceBarPanel.isVisible]
        case "hide":
            MenuYDebugHarness.holdShelf = false
            appState.menuBarManager.iceBarPanel.close()
            return ["visible": appState.menuBarManager.iceBarPanel.isVisible]
        case "search":
            guard let query = command["query"] as? String, query.count <= 256,
                  let field = findSearchField(appState.menuBarManager.iceBarPanel.contentView) else { throw CommandError.invalid("Visible native search field missing") }
            field.stringValue = query
            field.sendAction(field.action, to: field.target)
            try? await Task.sleep(for: .milliseconds(160))
            return ["query": field.stringValue, "ui": ownShelfAXSnapshot(), "evidence": "actual NSSearchField action and own AX view"]
        case "native_menu":
            return try await nativeMenu(command)
        case "cancel_menu":
            let item = try fixtureItem(command)
            guard let pid = item.sourcePID else { throw CommandError.invalid("Missing source PID") }
            postKey(53, pid: pid)
            try? await Task.sleep(for: .milliseconds(180))
            return ["client": fixtureState(), "evidence": "Escape posted only to fixture source"]
        case "pin":
            let item = try fixtureItem(command)
            guard let desired = command["value"] as? Bool else { throw CommandError.invalid("pin value must be boolean") }
            guard await wait(until: { !appState.shelfManager.isBusy }) else { throw CommandError.invalid("Native operation remained busy") }
            let before = itemEvidence(item)
            if appState.shelfManager.isPinned(item) != desired { await appState.shelfManager.toggle(item) }
            await appState.shelfManager.refresh()
            let after = itemEvidence(item)
            guard appState.shelfManager.message == nil else { throw CommandError.invalid(appState.shelfManager.message!) }
            return ["before": before, "after": after, "desired": desired, "physicallyVerified": after["pinned"] as? Bool == desired]
        case "preferences":
            try configurePreferences(command)
            return ["preferences": preferenceSnapshot(), "evidence": "shipping validated preference setters"]
        case "acknowledge_activity":
            appState.activity.acknowledgeAll()
            return ["activityApps": appState.activity.changedAppCount]
        case "enabled":
            guard let desired = command["value"] as? Bool else { throw CommandError.invalid("enabled value must be boolean") }
            if appState.shelfManager.isEnabled != desired { appState.shelfManager.toggleEnabled() }
            try? await Task.sleep(for: .milliseconds(220))
            return ["enabled": appState.shelfManager.isEnabled]
        case "quit":
            MenuYDebugHarness.holdShelf = false
            return ["request": "normal NSApplication termination; final restoration is in diagnostics.exit.json"]
        default: throw CommandError.invalid("Unsupported operation")
        }
    }
    private func nativeMenu(_ command: [String: Any]) async throws -> [String: Any] {
        guard let appState else { throw CommandError.invalid("Missing app state") }
        let item = try fixtureItem(command), index = command["index"] as! Int
        let buttonName = command["button"] as? String ?? "left"
        guard ["left", "right"].contains(buttonName) else { throw CommandError.invalid("Unsupported mouse button") }
        let modifiers = try flags(command["modifiers"])
        let before = fixtureEvents().count
        let started = Date().timeIntervalSince1970
        await appState.shelfManager.activate(item, button: buttonName == "right" ? .right : .left,
            modifiers: modifiers, clickCount: min(2, max(1, command["clickCount"] as? Int ?? 1)), closeShelf: true)
        let opened = await wait(3) {
            self.fixtureEvents().dropFirst(before).contains { ($0["menuOpened"] as? Int) == index && ($0["timestamp"] as? Double ?? 0) >= started }
        }
        var selected = false
        if command["select"] as? Bool == true, opened, let pid = item.sourcePID {
            postKey(125, pid: pid)
            try? await Task.sleep(for: .milliseconds(70))
            postKey(36, pid: pid)
            selected = await wait(3) {
                self.fixtureEvents().dropFirst(before).contains { ($0["selection"] as? Int) == index && ($0["timestamp"] as? Double ?? 0) >= started }
            }
        }
        let events = Array(fixtureEvents().dropFirst(before))
        return ["sourcePID": item.sourcePID ?? 0, "key": item.info.description,
            "transportError": appState.shelfManager.message ?? "", "clientMenuOpened": opened,
            "clientSelection": selected, "clientEvents": events,
            "evidence": "original fixture menuWillOpen/menuDidClose/selection, not an event-tap echo"]
    }
    private func flags(_ raw: Any?) throws -> NSEvent.ModifierFlags {
        guard raw != nil else { return [] }
        guard let names = raw as? [String], names.count <= 4 else { throw CommandError.invalid("modifiers must be string array") }
        var flags = NSEvent.ModifierFlags()
        for name in names {
            switch name { case "option": flags.insert(.option); case "shift": flags.insert(.shift); case "control": flags.insert(.control); case "command": flags.insert(.command)
            default: throw CommandError.invalid("Unsupported modifier") }
        }
        return flags
    }
    private func configurePreferences(_ command: [String: Any]) throws {
        guard let appState else { return }
        let prefs = appState.preferences
        if let opacity = command["opacity"] as? Double { prefs.opacity = opacity }
        if let size = command["iconSize"] as? Double { prefs.iconSize = size }
        if let name = command["style"] as? String {
            guard let style = MenuYBarStyle(rawValue: name) else { throw CommandError.invalid("Unknown style") }; prefs.style = style
        }
        if let name = command["sortMode"] as? String {
            guard let mode = MenuYSortMode(rawValue: name) else { throw CommandError.invalid("Unknown sort mode") }; prefs.sortMode = mode
        }
        if let raw = command["rules"] {
            guard let rules = raw as? [[String: Any]], rules.count <= 128 else { throw CommandError.invalid("Invalid rules") }
            prefs.rules = try rules.map {
                guard let pattern = $0["pattern"] as? String, let priority = $0["priority"] as? Int else { throw CommandError.invalid("Invalid rule fields") }
                return MenuYSortRule(pattern: pattern, priority: priority)
            }
        }
        if let activity = command["activityEnabled"] as? Bool { prefs.activityEnabled = activity }
    }
    private func hoverScenario() async throws -> [String: Any] {
        guard let appState, let screen = NSScreen.main,
              let id = appState.menuBarManager.section(withName: .visible)?.controlItem.windowID,
              let entry = Bridging.getWindowFrame(for: id) else { throw CommandError.invalid("Real native entry missing") }
        MenuYDebugHarness.holdShelf = false
        let original = CGEvent(source: nil)?.location
        defer { if let original { movePointer(original) } }
        let display = CGDisplayBounds(screen.displayID)
        let outside = CGPoint(x: display.midX, y: display.minY + display.height * 0.6)
        movePointer(outside); try? await Task.sleep(for: .milliseconds(350))
        let before = appState.menuBarManager.iceBarPanel.isVisible
        let focusBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        movePointer(CGPoint(x: entry.midX, y: entry.midY))
        let panel = appState.menuBarManager.iceBarPanel
        let shown = await wait(4, until: { panel.isVisible })
        let frame = panel.frame
        let focusAfter = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? display.maxY
        let inside = CGPoint(x: frame.midX, y: primaryTop-frame.midY)
        movePointer(inside); try? await Task.sleep(for: .milliseconds(300))
        let stayed = panel.isVisible
        MenuYEvidence.capture(appState: appState)
        movePointer(outside)
        let hidden = await wait(2, until: { !panel.isVisible })
        return ["before": before, "afterEntry": shown, "insideShelf": stayed, "afterLeave": !hidden,
            "focusBefore": focusBefore, "focusAfter": focusAfter, "frame": rectangle(frame), "opacity": panel.alphaValue,
            "passed": !before && shown && stayed && hidden && focusBefore == focusAfter,
            "evidence": "real guest hardware pointer plus normal hover controller"]
    }
    private func movePointer(_ point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    private func postKey(_ code: CGKeyCode, pid: pid_t) {
        guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "io.novarock.MacMenuY.Fixture" else { return }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
            event.flags = []; event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid)); event.postToPid(pid)
        }
    }
    private func findSearchField(_ root: NSView?) -> NSSearchField? {
        guard let root else { return nil }
        if let field = root as? NSSearchField { return field }
        return root.subviews.lazy.compactMap { self.findSearchField($0) }.first
    }
    private func fixtureState() -> [String: Any] {
        guard let file = fixtureFile, let data = try? Data(contentsOf: file),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return result
    }
    private func fixtureEvents() -> [[String: Any]] { fixtureState()["opens"] as? [[String: Any]] ?? [] }
    private func itemEvidence(_ item: MenuBarItem) -> [String: Any] {
        guard let appState else { return [:] }
        let latest = MenuBarItem(windowID: item.windowID)
        return ["id": item.windowID, "key": item.info.description, "title": item.title ?? "", "name": item.displayName,
            "sourcePID": item.sourcePID ?? 0, "hostPID": item.ownerPID, "onScreen": latest?.isOnScreen ?? false,
            "frame": rectangle(Bridging.getWindowFrame(for: item.windowID) ?? .zero),
            "pinned": appState.shelfManager.isPinned(item), "movable": item.isMovable, "hideable": item.canBeHidden,
            "hasImage": appState.imageCache.images[item.windowID] != nil]
    }
    private func preferenceSnapshot() -> [String: Any] {
        guard let appState else { return [:] }
        let prefs = appState.preferences
        return ["opacity": prefs.opacity, "iconSize": prefs.iconSize, "style": prefs.style.rawValue,
            "sortMode": prefs.sortMode.rawValue, "rules": prefs.rules.map { ["pattern": $0.pattern, "priority": $0.priority] }]
    }
    private func snapshot() -> [String: Any] {
        guard let appState else { return [:] }
        let items = appState.itemManager.itemCache.allItems.filter { $0.info.namespace != .ice }
        let ordered = appState.preferences.ordered(items, hasActivity: appState.activity.hasActivity)
        let panel = appState.menuBarManager.iceBarPanel
        appState.shelfManager.writeDiagnostics()
        return ["pid": ProcessInfo.processInfo.processIdentifier, "timestamp": Date().timeIntervalSince1970,
            "accessibility": AXIsProcessTrusted(), "screenCapture": ScreenCapture.cachedCheckPermissions(reset: true),
            "enabled": appState.shelfManager.isEnabled, "busy": appState.shelfManager.isBusy,
            "error": appState.shelfManager.message ?? "", "lastNativeAction": appState.shelfManager.lastNativeAction,
            "panelVisible": panel.isVisible, "panelFrame": rectangle(panel.frame), "panelOpacity": panel.alphaValue,
            "preferences": preferenceSnapshot(), "pins": appState.shelfManager.pinned.sorted(),
            "items": items.map(itemEvidence), "orderedKeys": ordered.map { $0.info.description },
            "changedApps": appState.activity.changedAppCount, "unreadCount": appState.activity.unreadCount,
            "unreadStale": appState.activity.unreadStale.sorted(),
            "pendingRestoration": appState.itemManager.pendingRestorationWindowIDs,
            "screens": NSScreen.screens.map { ["id": $0.displayID, "frame": rectangle($0.frame), "visible": rectangle($0.visibleFrame), "menuBarHeight": $0.getMenuBarHeight() ?? NSStatusBar.system.thickness] },
            "coverWindows": appState.menuCover.diagnostics()]
    }
    private func ownShelfAXSnapshot() -> [String: Any] {
        guard let panel=appState?.menuBarManager.iceBarPanel,panel.isVisible,
              let root=panel.contentView else { return ["available":false] }
        // Query native in-process accessibility objects, not AXUIElement(selfPID),
        // whose synchronous IPC can wait for this same main actor.
        var labels=[String](), text=[String](), budget=600
        func walk(_ object:Any,depth:Int) {
            guard budget>0,depth<14 else { return };budget-=1
            guard let element=object as? NSAccessibilityProtocol else { return }
            let role=element.accessibilityRole()?.rawValue ?? ""
            let label=element.accessibilityLabel() ?? ""
            if role == "AXButton",label.hasPrefix("打开 ") { labels.append(label) }
            if role == "AXStaticText",let value=element.accessibilityValue() as? String { text.append(value) }
            for child in element.accessibilityChildren() ?? [] { walk(child,depth:depth+1) }
        }
        walk(root,depth:0)
        return ["available":true,"nativeItemButtons":labels,"itemButtonCount":labels.count,
                "text":text,"truncated":budget<=0]
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    private func rectangle(_ frame: CGRect) -> [String: Double] {
        ["x": frame.origin.x, "y": frame.origin.y, "width": frame.width, "height": frame.height]
    }
    private func write(_ result: [String: Any], id: String) {
        guard let resultFolder, let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: resultFolder.appendingPathComponent(id+".json"), options: .atomic)
    }
    private enum CommandError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
    }
}
#endif
