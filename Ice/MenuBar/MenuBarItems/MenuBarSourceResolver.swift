// macOS 26 hosts status windows in Control Center. Recover the source app
// from the matching center of its AXExtrasMenuBar child, including offscreen
// coordinates. Inspired by Icey's SourcePIDCache (GPL-3.0).
import AppKit
import Combine

final class MenuBarSourceResolver {
    struct Source: Equatable {
        let pid: pid_t
        let bundleID: String
        let slot: Int
        let siblingCount: Int
        var stableIdentifier: String? = nil
        var identitySlot: Int = 0
    }
    private static let lock = NSLock()
    private static var sources = [CGWindowID: Source]()
    private static var nextIdentitySlots = [pid_t: Int]()
    private static var running = false
    private static var lastSearch = Date.distantPast
    private static let queue = DispatchQueue(label: "io.novarock.MacMenuY.source-resolver", qos: .utility)
    private static var timer: AnyCancellable?

    static func lookup(_ windowID: CGWindowID) -> Source? {
        lock.lock(); let source = sources[windowID]; lock.unlock()
        guard let source, let app = NSRunningApplication(processIdentifier: source.pid), !app.isTerminated else { return nil }
        if !source.bundleID.hasPrefix("pid."), app.bundleIdentifier != source.bundleID { return nil }
        return source
    }

    static func sameApplicationFamily(_ lhs: pid_t, _ rhs: pid_t) -> Bool {
        if lhs == rhs { return true }
        guard let left = NSRunningApplication(processIdentifier: lhs),
              let right = NSRunningApplication(processIdentifier: rhs),
              !left.isTerminated, !right.isTerminated else { return false }
        return NativeInteractionPolicy.sameApplicationFamily(left.bundleURL ?? left.executableURL,
                                                              right.bundleURL ?? right.executableURL)
    }

    @MainActor static func stop() { timer?.cancel(); timer=nil }

    @MainActor static func start(appState: AppState) {
        timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
            .merge(with: Just(.now)).sink { [weak appState] _ in
                guard let appState else { return }
                update(appState: appState)
            }
    }

    @MainActor private static func update(appState: AppState) {
        guard AXIsProcessTrusted(), !appState.itemManager.isMovingItem else { return }
        let windows = Bridging.getWindowList(option: [.menuBarItems, .activeSpace])
            .compactMap { WindowInfo(windowID: $0) }.filter(\.isMenuBarItem)
        let apps = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated && $0.isFinishedLaunching }
        let activeIDs = Set(windows.map(\.windowID))
        lock.lock()
        sources = sources.filter { activeIDs.contains($0.key) }
        let pending = windows.filter { sources[$0.windowID] == nil }
        let knownPIDs = Set(sources.values.map(\.pid))
        let livePIDs = Set(apps.map(\.processIdentifier))
        nextIdentitySlots = nextIdentitySlots.filter { livePIDs.contains($0.key) }
        guard !running, !windows.isEmpty, Date().timeIntervalSince(lastSearch) > 4 else { lock.unlock(); return }
        running = true; lastSearch = .now
        lock.unlock()
        let searchApps = pending.isEmpty ? apps.filter { knownPIDs.contains($0.processIdentifier) } : apps
        queue.async {
            var matches = [CGWindowID: Source]()
            let boundsByID = Dictionary(uniqueKeysWithValues: windows.compactMap { window -> (CGWindowID,CGRect)? in
                guard let bounds = Bridging.getWindowFrame(for: window.windowID) else { return nil }
                return (window.windowID,bounds)
            })
            // Prefer a named, real source to Control Center's empty proxy AX children.
            for app in searchApps.sorted(by: { $0.bundleIdentifier != "com.apple.controlcenter" && $1.bundleIdentifier == "com.apple.controlcenter" }) {
                let root = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(root, 0.08)
                guard let raw = attribute(root, "AXExtrasMenuBar"), CFGetTypeID(raw) == AXUIElementGetTypeID() else { continue }
                let bar = raw as! AXUIElement
                guard let children = attribute(bar, "AXChildren") as? [AXUIElement] else { continue }
                let identifiers=children.map { child -> String? in
                    AXUIElementSetMessagingTimeout(child,0.08)
                    return MenuBarStableIdentity.acceptedIdentifier(attribute(child,"AXIdentifier") as? String)
                }
                let identifierCounts=identifiers.compactMap { $0 }.reduce(into:[String:Int]()) { $0[$1,default:0] += 1 }
                for (index, child) in children.enumerated() {
                    AXUIElementSetMessagingTimeout(child, 0.08)
                    guard let frame = frame(child), frame.width > 0, frame.height > 0 else { continue }
                    for window in windows where matches[window.windowID] == nil {
                        guard let bounds = boundsByID[window.windowID] else { continue }
                        let exactCenter = hypot(frame.midX - bounds.midX, frame.midY - bounds.midY) <= 1
                        // A music/progress item may expose only its icon through AX,
                        // while its hosted window also contains a long text title.
                        let compactIconInWideItem = bounds.width < 1024 && bounds.width > frame.width + 24 &&
                            abs(frame.midY - bounds.midY) <= 1 &&
                            bounds.contains(CGPoint(x: frame.midX, y: frame.midY))
                        guard exactCenter || compactIconInWideItem else { continue }
                        matches[window.windowID] = Source(pid: app.processIdentifier,
                            bundleID: app.bundleIdentifier ?? "pid.\(app.processIdentifier)",
                            slot: index, siblingCount: children.count,
                            stableIdentifier: identifiers[index].flatMap { identifierCounts[$0] == 1 ? $0 : nil })
                    }
                }
            }
            lock.lock()
            // Preserve existing generic slots while a source app is running;
            // newly registered generic windows get monotonically allocated slots.
            // On a fresh launch, CG window registration order supplies the fallback.
            let genericIDs = Set(windows.filter { $0.title == "Item-0" }.map(\.windowID))
            for id in matches.keys.sorted() {
                guard var source = matches[id] else { continue }
                if let old = sources[id], old.pid == source.pid, old.bundleID == source.bundleID {
                    source.identitySlot = old.identitySlot
                    if genericIDs.contains(id) { nextIdentitySlots[source.pid] = max(nextIdentitySlots[source.pid] ?? 0,old.identitySlot+1) }
                    source.stableIdentifier = source.stableIdentifier ?? old.stableIdentifier
                } else if genericIDs.contains(id) {
                    source.identitySlot = nextIdentitySlots[source.pid] ?? 0
                    nextIdentitySlots[source.pid] = source.identitySlot+1
                } else { source.identitySlot = source.slot }
                matches[id] = source
            }
            sources.merge(matches) { _, new in new }
            running = false
            lock.unlock()
            if !matches.isEmpty {
                Task { @MainActor [weak appState] in
                    guard let appState else { return }
                    await appState.itemManager.refreshItems()
                    appState.shelfManager.writeDiagnostics()
                }
            }
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = attribute(element, "AXPosition"), let s = attribute(element, "AXSize"),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}
