import AppKit

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
        if commandFile != nil {
            let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.consumeCommand() }
            }
            commandTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        write()
    }

    @objc func addItem() {
        let index = nextIndex; nextIndex += 1
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if !CommandLine.arguments.contains("--generic-titles") { status.autosaveName = "Fixture-\(index)" }
        if let button = status.button {
            if !CommandLine.arguments.contains("--no-stable-ax") { button.setAccessibilityIdentifier("fixture.item.\(index)") }
            button.tag = index; button.target = self; button.action = #selector(openMenu(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statuses.append(status)
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
        return ["timestamp": Date().timeIntervalSince1970, "eventType": event.map { Int($0.type.rawValue) } ?? -1,
                "modifiers": modifiers, "modifierFlags": flags.rawValue, "clickCount": event?.clickCount ?? 0]
    }

    @objc func openMenu(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let right = event?.type == .rightMouseUp || event?.type == .rightMouseDown
        var evidence = eventEvidence(); evidence["index"] = sender.tag; evidence["button"] = right ? "right" : "left"
        opens.append(evidence); write()
        let option = event?.modifierFlags.contains(.option) == true
        let menu = NSMenu(title: "Fixture \(sender.tag)")
        menu.delegate = self
        menuIndexes[ObjectIdentifier(menu)] = sender.tag
        let title = "Fixture \(sender.tag) · \(right ? "Right" : "Left")\(option ? " + Option" : "") menu"
        menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        let ping = NSMenuItem(title: "Record selection", action: #selector(recordSelection(_:)), keyEquivalent: "p")
        ping.keyEquivalentModifierMask = []; ping.target = self; ping.tag = sender.tag; menu.addItem(ping)
        let badge = NSMenuItem(title: "Set 3 unread notifications", action: #selector(addBadge(_:)), keyEquivalent: "")
        badge.target = self; badge.tag = sender.tag; menu.addItem(badge)
        let clear = NSMenuItem(title: "Clear unread notifications", action: #selector(clearBadge(_:)), keyEquivalent: "")
        clear.target = self; clear.tag = sender.tag; menu.addItem(clear)
        menu.addItem(.separator())
        let add = NSMenuItem(title: "Add fixture item", action: #selector(addItem), keyEquivalent: "")
        add.target = self; menu.addItem(add)
        let remove = NSMenuItem(title: "Remove last fixture item", action: #selector(removeItem), keyEquivalent: "")
        remove.target = self; menu.addItem(remove)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        statuses.first(where: { $0.button === sender })?.popUpMenu(menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard let index = menuIndexes[ObjectIdentifier(menu)] else { return }
        openMenus.insert(index)
        var evidence = eventEvidence(); evidence["menuOpened"] = index; evidence["title"] = menu.title
        opens.append(evidence); write()
    }
    func menuDidClose(_ menu: NSMenu) {
        guard let index = menuIndexes.removeValue(forKey: ObjectIdentifier(menu)) else { return }
        openMenus.remove(index)
        var evidence = eventEvidence(); evidence["menuClosed"] = index
        opens.append(evidence); write()
    }
    @objc func recordSelection(_ sender: NSMenuItem) {
        var evidence = eventEvidence(); evidence["selection"] = sender.tag
        opens.append(evidence); write()
    }
    @objc func addBadge(_ sender: NSMenuItem) { applyBadge(index: sender.tag, unreadCount: 3); write() }
    @objc func clearBadge(_ sender: NSMenuItem) { applyBadge(index: sender.tag, unreadCount: 0); write() }
    @objc func removeItem() {
        if let last = statuses.popLast() {
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

    private func write() {
        guard let output else { return }
        let value: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "count": statuses.count,
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
