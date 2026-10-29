import AppKit

// Independent fixture-owned read-only WindowServer evidence. Status windows
// may be hosted by Control Center, so the source PID alone cannot locate them.
@_silgen_name("CGSMainConnectionID") private func fixtureConnection() -> UInt32
@_silgen_name("CGSGetWindowCount") private func fixtureWindowCount(_ cid: UInt32, _ target: UInt32, _ count: inout Int32) -> CGError
@_silgen_name("CGSGetProcessMenuBarWindowList") private func fixtureMenuWindows(_ cid: UInt32, _ target: UInt32, _ capacity: Int32, _ list: UnsafeMutablePointer<CGWindowID>, _ count: inout Int32) -> CGError

/// A real native status-item client. --command-file only mutates this fixture's
/// own items; it never posts input to other applications.
@MainActor final class Fixture: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statuses = [NSStatusItem]()
    private var output: URL!
    private var commandFile: URL?
    private var commandTimer: Timer?
    private var lastCommandData: Data?
    private var nextIndex = 1
    private var opens = [[String: Any]]()
    private var commands = [[String: Any]]()
    private var badges = [Int: Int]()
    private var openMenus = Set<Int>()
    private var menuIndexes = [ObjectIdentifier: Int]()
    private var menuModes = [ObjectIdentifier: String]()

    private func argument(_ flag: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let count = min(1000, max(1, argument("--count").flatMap(Int.init) ?? 32))
        output = URL(fileURLWithPath: argument("--output") ?? "/tmp/macmenuy-fixture.json")
        commandFile = argument("--command-file").map { URL(fileURLWithPath: $0) }
        for _ in 0..<count { addItem() }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            // This timer is installed on RunLoop.main in common modes. Run the
            // observation synchronously so nested NSMenu tracking cannot defer
            // metadata refresh behind a queued main-actor Task.
            MainActor.assumeIsolated {
                self?.consumeCommand()
                // Callback arrays are untouched by observation refresh.
                self?.write()
            }
        }
        commandTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        write()
    }

    @objc func addItem() {
        let index = nextIndex; nextIndex += 1
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if !CommandLine.arguments.contains("--generic-titles") { status.autosaveName = "Fixture-\(index)" }
        if let button = status.button {
            if !CommandLine.arguments.contains("--no-stable-ax") { button.setAccessibilityIdentifier("fixture.item.\(index)") }
            button.tag = index
            if index < 17 {
                button.target = self; button.action = #selector(openMenu(_:))
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
        }
        statuses.append(status)
        if index >= 17 {
            // A real declarative AppKit client; native AppKit dispatch owns menu
            // opening, without the custom target/action interception above.
            status.menu = makeMenu(index: index, mode: "declarative", right: false, option: false)
        }
        applyBadge(index: index, unreadCount: 0)
        if output != nil { write() }
    }

    private func applyBadge(index: Int, unreadCount: Int) {
        guard let button = statuses.first(where: { $0.button?.tag == index })?.button else { return }
        let count = min(99999, max(0, unreadCount))
        badges[index] = count
        let name = String(format: "F%02d", index)
        button.title = name + (count > 0 ? " •\(count)" : "")
        button.setAccessibilityLabel("Fixture \(index)")
        button.setAccessibilityHelp("\(count) unread notifications")
        button.toolTip = "Fixture \(index), \(count) unread notifications"
    }

    private func eventEvidence() -> [String: Any] {
        let event = NSApp.currentEvent
        let flags = event?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        var modifiers = [String]()
        for (flag, label) in [(NSEvent.ModifierFlags.option,"option"),(.command,"command"),(.control,"control"),(.shift,"shift"),(.capsLock,"capsLock")] {
            if flags.contains(flag) { modifiers.append(label) }
        }
        var evidence: [String: Any] = ["timestamp": Date().timeIntervalSince1970, "eventType": event.map { Int($0.type.rawValue) } ?? -1,
                "modifiers": modifiers, "modifierFlags": flags.rawValue, "clickCount": event?.clickCount ?? 0,
                "windowNumber": event?.windowNumber ?? 0, "cgEventAvailable": event?.cgEvent != nil]
        if let cg = event?.cgEvent {
            evidence["cgEventType"] = cg.type.rawValue
            evidence["targetPID"] = cg.getIntegerValueField(.eventTargetUnixProcessID)
            evidence["buttonNumber"] = cg.getIntegerValueField(.mouseEventButtonNumber)
            evidence["windowUnderPointer"] = cg.getIntegerValueField(.mouseEventWindowUnderMousePointer)
            evidence["canHandle"] = cg.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)
            // This is the private window hint at hexadecimal field 0x33, matching
            // the collector's native routing trace; no event field is changed.
            evidence["private33"] = cg.getIntegerValueField(CGEventField(rawValue: 0x33)!)
            evidence["sourceUserData"] = cg.getIntegerValueField(.eventSourceUserData)
        }
        return evidence
    }

    private func buttonEvidence(index: Int, mode: String) -> [String: Any] {
        let event = NSApp.currentEvent
        let right = event?.type == .rightMouseUp || event?.type == .rightMouseDown
        var evidence = eventEvidence()
        evidence["index"] = index; evidence["button"] = right ? "right" : "left"; evidence["mode"] = mode
        return evidence
    }

    @objc func openMenu(_ sender: NSStatusBarButton) {
        let evidence = buttonEvidence(index: sender.tag, mode: "custom-action")
        opens.append(evidence); write()
        let right = evidence["button"] as? String == "right"
        let option = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        let menu = makeMenu(index: sender.tag, mode: "custom-action", right: right, option: option)
        statuses.first(where: { $0.button === sender })?.popUpMenu(menu)
    }

    private func makeMenu(index: Int, mode: String, right: Bool, option: Bool) -> NSMenu {
        let menu = NSMenu(title: "Fixture \(index)")
        menu.delegate = self
        menuIndexes[ObjectIdentifier(menu)] = index
        menuModes[ObjectIdentifier(menu)] = mode
        let title = "Fixture \(index) · \(right ? "Right" : "Left")\(option ? " + Option" : "") menu"
        menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        let ping = NSMenuItem(title: "Record selection", action: #selector(recordSelection(_:)), keyEquivalent: "p")
        ping.keyEquivalentModifierMask = []; ping.target = self; ping.tag = index; menu.addItem(ping)
        let badge = NSMenuItem(title: "Set 3 unread notifications", action: #selector(addBadge(_:)), keyEquivalent: "")
        badge.target = self; badge.tag = index; menu.addItem(badge)
        let clear = NSMenuItem(title: "Clear unread notifications", action: #selector(clearBadge(_:)), keyEquivalent: "")
        clear.target = self; clear.tag = index; menu.addItem(clear)
        menu.addItem(.separator())
        let add = NSMenuItem(title: "Add fixture item", action: #selector(addItem), keyEquivalent: "")
        add.target = self; menu.addItem(add)
        let remove = NSMenuItem(title: "Remove last fixture item", action: #selector(removeItem), keyEquivalent: "")
        remove.target = self; menu.addItem(remove)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard let index = menuIndexes[ObjectIdentifier(menu)] else { return }
        let mode = menuModes[ObjectIdentifier(menu)] ?? "custom-action"
        if mode == "declarative" {
            let click = buttonEvidence(index: index, mode: mode)
            opens.append(click)
            let right = click["button"] as? String == "right"
            let option = NSApp.currentEvent?.modifierFlags.contains(.option) == true
            menu.items.first?.title = "Fixture \(index) · \(right ? "Right" : "Left")\(option ? " + Option" : "") menu"
        }
        openMenus.insert(index)
        var evidence = eventEvidence(); evidence["menuOpened"] = index; evidence["title"] = menu.title; evidence["mode"] = mode
        opens.append(evidence); write()
    }
    func menuDidClose(_ menu: NSMenu) {
        let identity = ObjectIdentifier(menu)
        guard let index = menuIndexes[identity] else { return }
        let mode = menuModes[identity] ?? "custom-action"
        if mode != "declarative" { menuIndexes.removeValue(forKey: identity); menuModes.removeValue(forKey: identity) }
        openMenus.remove(index)
        var evidence = eventEvidence(); evidence["menuClosed"] = index; evidence["mode"] = mode
        opens.append(evidence); write()
    }
    @objc func recordSelection(_ sender: NSMenuItem) {
        var evidence = eventEvidence(); evidence["selection"] = sender.tag
        evidence["mode"] = sender.menu.flatMap { menuModes[ObjectIdentifier($0)] } ?? (sender.tag >= 17 ? "declarative" : "custom-action")
        opens.append(evidence); write()
    }
    @objc func addBadge(_ sender: NSMenuItem) { applyBadge(index: sender.tag, unreadCount: 3); write() }
    @objc func clearBadge(_ sender: NSMenuItem) { applyBadge(index: sender.tag, unreadCount: 0); write() }
    @objc func removeItem() {
        if let last = statuses.popLast() {
            if let menu = last.menu { menuIndexes.removeValue(forKey: ObjectIdentifier(menu)); menuModes.removeValue(forKey: ObjectIdentifier(menu)) }
            if let index = last.button?.tag { badges.removeValue(forKey: index) }
            NSStatusBar.system.removeStatusItem(last)
        }
        write()
    }

    private func consumeCommand() {
        guard let file = commandFile, let data = try? Data(contentsOf: file), data.count <= 65536,
              data != lastCommandData else { return }
        lastCommandData = data
        var evidence: [String: Any] = ["timestamp": Date().timeIntervalSince1970]
        guard let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = (command["op"] ?? command["action"]) as? String else {
            evidence["error"] = "Expected a JSON object with op/action"; commands.append(evidence); write(); return
        }
        evidence["op"] = action; evidence["id"] = command["id"] ?? ""
        switch action {
        case "set_badge", "clear_badge":
            guard let index = command["index"] as? Int,
                  statuses.contains(where: { $0.button?.tag == index }) else {
                evidence["error"] = "Fixture index not found"; break
            }
            let count = action == "clear_badge" ? 0 : (command["unreadCount"] as? Int ?? command["count"] as? Int ?? 0)
            applyBadge(index: index, unreadCount: count)
            evidence["index"] = index; evidence["unreadCount"] = badges[index] ?? 0
        case "add": addItem()
        case "remove": removeItem()
        case "reset_evidence": opens.removeAll(); commands.removeAll()
        default: evidence["error"] = "Unsupported fixture command"
        }
        commands.append(evidence); write()
    }

    private func rectangle(_ frame: CGRect) -> [String: Double] {
        ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
    }

    private func nativeItems() -> [[String: Any]] {
        var total: Int32 = 0
        let connection = fixtureConnection()
        _ = fixtureWindowCount(connection, 0, &total)
        var ids = [CGWindowID](repeating: 0, count: max(4096, Int(total)))
        var count: Int32 = 0
        let result = fixtureMenuWindows(connection, 0, Int32(ids.count), &ids, &count)
        let descriptions = result == .success ? CGWindowListCreateDescriptionFromArray(
            ids.prefix(Int(count)).map(NSNumber.init(value:)) as CFArray) as? [[String: Any]] ?? [] : []
        let onscreen = Set((CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []).compactMap {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        })
        return statuses.compactMap { status -> [String: Any]? in
            guard let button = status.button else { return nil }
            let index = button.tag
            let name = status.autosaveName ?? ""
            let nativeStatusWindows = descriptions.filter {
                ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == Int(CGWindowLevelForKey(.statusWindow))
            }
            let screenFrameAppKit = button.window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) }
            let primaryTop = NSScreen.screens.first?.frame.maxY ?? CGDisplayBounds(CGMainDisplayID()).height
            let screenFrameQuartz = screenFrameAppKit.map {
                CGRect(x: $0.minX, y: primaryTop - $0.maxY, width: $0.width, height: $0.height)
            }
            func matchesSourceFrame(_ raw: [String: Any]) -> Bool {
                guard let expected = screenFrameQuartz, let bounds = raw[kCGWindowBounds as String] as? [String: Any],
                      let actual = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
                return abs(actual.minX - expected.minX) <= 2 && abs(actual.minY - expected.minY) <= 2 &&
                       abs(actual.width - expected.width) <= 2 && abs(actual.height - expected.height) <= 2
            }
            var matches = nativeStatusWindows.filter { ($0[kCGWindowName as String] as? String) == name && !name.isEmpty }
            var method = "autosave-name"
            if matches.isEmpty {
                // CGWindowName can be redacted for a client without Screen
                // Recording. Native own-view geometry and a unique real menu
                // window ID still provide independent source identity evidence.
                let number = button.window?.windowNumber ?? 0
                matches = nativeStatusWindows.filter {
                    ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == number && matchesSourceFrame($0)
                }
                method = "proxy-window-id-and-source-frame"
                if matches.isEmpty { matches = nativeStatusWindows.filter(matchesSourceFrame); method = "unique-source-view-frame" }
            }
            var item: [String: Any] = ["index": index, "name": name, "sourcePID": ProcessInfo.processInfo.processIdentifier,
                "mode": status.menu == nil ? "custom-action" : "declarative", "nativeMatchCount": matches.count, "nativeIdentityMethod": method,
                "nativeQueryError": result.rawValue, "proxyWindowNumber": button.window?.windowNumber ?? 0,
                "buttonFrameAppKit": rectangle(button.frame), "buttonAccessibilityFrameAppKit": rectangle(button.accessibilityFrame())]
            if let window = button.window { item["proxyWindowFrameAppKit"] = rectangle(window.frame) }
            if let screenFrameAppKit { item["buttonScreenFrameAppKit"] = rectangle(screenFrameAppKit) }
            if let screenFrameQuartz { item["buttonScreenFrameQuartz"] = rectangle(screenFrameQuartz) }
            if matches.count == 1, let raw = matches.first,
               let id = raw[kCGWindowNumber as String] as? NSNumber,
               let bounds = raw[kCGWindowBounds as String] as? [String: Any],
               let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) {
                item["windowID"] = id; item["frameQuartz"] = rectangle(frame)
                item["hostPID"] = raw[kCGWindowOwnerPID as String] ?? 0; item["onScreen"] = onscreen.contains(id.uint32Value)
            }
            return item
        }
    }

    private func write() {
        guard let output else { return }
        let value: [String: Any] = ["nativeTimestamp": Date().timeIntervalSince1970, "nativeItems": nativeItems(), "nativeScreenCapture": CGPreflightScreenCaptureAccess(), "pid": ProcessInfo.processInfo.processIdentifier, "count": statuses.count,
            "indexes": statuses.compactMap { $0.button?.tag }, "opens": opens, "openMenus": openMenus.sorted(),
            "badges": Dictionary(uniqueKeysWithValues: badges.map { (String($0.key),$0.value) }), "commands": commands]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted,.sortedKeys]) {
            try? data.write(to: output, options: .atomic)
        }
    }
}
@main struct FixtureMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = Fixture(); app.delegate = delegate
        app.setActivationPolicy(.accessory); app.run()
    }
}
