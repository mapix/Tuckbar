// MacMenuY contributors — GPL-3.0; see LICENSE and NOTICE.md.
// Explicitly authorized Host metadata observer. Never posts pointer/key input.
// --terminate-collector is a separately requested public normal Quit operation.
import Cocoa
import ApplicationServices
import Darwin
import CryptoKit

private func hardwareModel() -> String {
    var size: size_t = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0, size < 4096 else { return "" }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "" }
    return String(cString: bytes)
}
let model = hardwareModel()
let args = Array(CommandLine.arguments.dropFirst())
let fixedModel = "Mac17,6"
let workspace = "/Users/mac/workspaces/MacMenuY"
let collectorBundle = "io.novarock.MacMenuY"
let fixtureBundle = "io.novarock.MacMenuY.Fixture"
let allowedCollectors = [
    workspace + "/build/Verification/Build/Products/Release/MacMenuY.app",
    workspace + "/build/DerivedData/Build/Products/Release/MacMenuY.app",
    workspace + "/build/Production/Build/Products/Release/MacMenuY.app"
]
let fixedFixture = workspace + "/build/native-interaction/MenuYFixture.app"
func canonical(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
func refuse(_ message: String) -> Never { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(78) }
var optIn = false, requestPermissions = false, terminateCollector = false, fastWindowOnly = false, tracePhases = false
var expectedModel: String?, collectorPath: String?, fixturePath: String?, output: String?, fixtureStatePath: String?
var i = 0
while i < args.count {
    switch args[i] {
    case "--verification-host": optIn = true; i += 1; continue
    case "--request-permissions": requestPermissions = true; i += 1; continue
    case "--terminate-collector": terminateCollector = true; i += 1; continue
    case "--fast-window-only": fastWindowOnly = true; i += 1; continue
    case "--trace-phases": tracePhases = true; i += 1; continue
    default: break
    }
    guard i + 1 < args.count else { refuse("Expected a value for " + args[i]) }
    switch args[i] {
    case "--expected-model": expectedModel = args[i + 1]
    case "--collector-path": collectorPath = canonical(args[i + 1])
    case "--fixture-path": fixturePath = canonical(args[i + 1])
    case "--fixture-state": fixtureStatePath = canonical(args[i + 1])
    case "--output": output = canonical(args[i + 1])
    default: refuse("Unsupported Host observer argument: " + args[i])
    }
    i += 2
}
// No NSWorkspace, AX, cursor or WindowServer call occurs before all guards.
guard optIn, expectedModel == fixedModel, model == fixedModel,
      let collectorPath, allowedCollectors.map(canonical).contains(collectorPath),
      let fixturePath, fixturePath == canonical(fixedFixture),
      Bundle(url: URL(fileURLWithPath: collectorPath))?.bundleIdentifier == collectorBundle,
      Bundle(url: URL(fileURLWithPath: fixturePath))?.bundleIdentifier == fixtureBundle else {
    refuse("Host observer needs --verification-host, exact Mac17,6 and fixed collector/fixture bundle paths")
}
func phase(_ name: String) {
    if tracePhases { FileHandle.standardError.write(Data(("HostNativeObserver phase: " + name + "\n").utf8)) }
}
phase("guards-complete")
if let fixtureStatePath, !fixtureStatePath.hasPrefix(canonical(workspace + "/artifacts") + "/") {
    refuse("Fixture evidence must be inside this workspace's artifacts directory")
}
if let output, !output.hasPrefix(canonical(workspace + "/artifacts") + "/") {
    refuse("Observer evidence must be inside this workspace's artifacts directory")
}
let bundles = Set([collectorBundle, fixtureBundle])
phase("NSWorkspace-running-applications")
let running = NSWorkspace.shared.runningApplications.filter { bundles.contains($0.bundleIdentifier ?? "") }
for app in running {
    let expected = app.bundleIdentifier == collectorBundle ? collectorPath : fixturePath
    guard canonical(app.bundleURL?.path ?? "") == expected else { refuse("Fixed bundle identity is running from an unexpected path") }
}
for bundle in bundles where running.filter({ $0.bundleIdentifier == bundle }).count > 1 {
    refuse("Ambiguous running instances for fixed bundle " + bundle)
}
if fastWindowOnly && (requestPermissions || terminateCollector) { refuse("Fast-window-only is strictly observation; no prompts or quit") }
if terminateCollector {
    guard !requestPermissions, let app = running.first(where: { $0.bundleIdentifier == collectorBundle }) else { refuse("Exact collector is not running") }
    let result: [String: Any] = ["model": model, "pid": app.processIdentifier,
        "bundle": collectorBundle, "bundlePath": collectorPath, "requestedAt": Date().timeIntervalSince1970,
        "accepted": app.terminate(), "method": "public NSRunningApplication.terminate; explicitly opted-in Host collector only"]
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])); exit(0)
}
if requestPermissions {
    _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
}
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func point(_ raw: CFTypeRef?) -> CGPoint? {
    guard let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    var result = CGPoint.zero
    return AXValueGetValue(raw as! AXValue, .cgPoint, &result) ? result : nil
}
func size(_ raw: CFTypeRef?) -> CGSize? {
    guard let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    var result = CGSize.zero
    return AXValueGetValue(raw as! AXValue, .cgSize, &result) ? result : nil
}
func rectangle(_ rect: CGRect) -> [String: Double] {
    ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
}
let display = CGDisplayBounds(CGMainDisplayID())
var axErrors = [[String: Any]]()
func tree(_ root: AXUIElement) -> (nodes: [[String: Any]], truncated: Bool) {
    var nodes = [[String: Any]](), visited = [AXUIElement](), budget = 2000
    func walk(_ element: AXUIElement, _ parent: Int?, _ depth: Int, _ relation: String) {
        guard budget > 0, depth < 20, !visited.contains(where: { CFEqual($0, element) }) else { return }
        budget -= 1; visited.append(element); AXUIElementSetMessagingTimeout(element, 0.8)
        var names: CFArray?
        let namesResult = AXUIElementCopyAttributeNames(element, &names)
        var roleValue: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(element, "AXRole" as CFString, &roleValue)
        let role = roleValue as? String ?? ""
        let index = nodes.count
        if namesResult != .success || roleResult != .success {
            axErrors.append(["node": index, "depth": depth, "attributeNamesError": namesResult.rawValue,
                             "roleError": roleResult.rawValue])
        }
        var node: [String: Any] = ["node": index, "depth": depth, "relation": relation, "role": role,
            "attributeNames": names as? [String] ?? [], "roleError": roleResult.rawValue]
        if let parent { node["parent"] = parent }
        for key in ["AXTitle", "AXDescription", "AXHelp", "AXIdentifier", "AXSubrole"] {
            if let value = attribute(element, key) as? String, !value.isEmpty { node[key] = value }
        }
        if role != "AXSecureTextField", let value = attribute(element, "AXValue") {
            if let value = value as? String, value.count <= 500 { node["AXValue"] = value }
            else if let value = value as? NSNumber { node["AXValue"] = value }
        }
        for key in ["AXEnabled", "AXHidden", "AXMinimized", "AXFocused", "AXSelected"] {
            if let value = attribute(element, key) as? NSNumber { node[key] = value }
        }
        if let position = point(attribute(element, "AXPosition")), let extent = size(attribute(element, "AXSize")) {
            let frame = CGRect(origin: position, size: extent)
            node["frame"] = rectangle(frame)
            node["intersectsDisplay"] = frame.width > 0 && frame.height > 0 && frame.intersects(display)
        }
        if let number = attribute(element, "AXWindowNumber") as? NSNumber { node["windowID"] = number }
        var actions: CFArray?
        if AXUIElementCopyActionNames(element, &actions) == .success { node["actions"] = actions as? [String] ?? [] }
        nodes.append(node)
        // AX can lazily construct/open status menus. Never inspect any menu
        // relation or menu-item children. Collector windows alone provide the
        // actual shelf InputView tree without touching its status-item menus.
        if ["AXMenu", "AXMenuBar", "AXMenuBarItem"].contains(role) { return }
        for relation in depth == 0 ? ["AXWindows"] : ["AXChildren"] {
            var related: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, relation as CFString, &related)
            if error != .success { axErrors.append(["node": index, "depth": depth, "attribute": relation, "error": error.rawValue]) }
            if let children = related as? [AXUIElement] {
                for child in children { walk(child, index, depth + 1, relation) }
            } else if let child = related, CFGetTypeID(child) == AXUIElementGetTypeID() {
                walk(child as! AXUIElement, index, depth + 1, relation)
            }
        }
    }
    walk(root, nil, 0, "root")
    return (nodes, budget == 0)
}
func modifierState(_ state: CGEventSourceStateID) -> [String: Any] {
    phase("CGEventSource-flagsState-" + String(state.rawValue))
    let flags = CGEventSource.flagsState(state)
    var names = [String]()
    for (flag, name) in [(CGEventFlags.maskCommand,"command"),(.maskAlternate,"option"),(.maskShift,"shift"),(.maskControl,"control"),(.maskAlphaShift,"capsLock"),(.maskSecondaryFn,"function")] {
        if flags.contains(flag) { names.append(name) }
    }
    return ["raw": flags.rawValue, "modifiers": names]
}
// privateState is not a global state pool. A static flagsState(-1) query can
// block in WindowServer; do not call it. No source instance is created here.
let modifierStates: [String: Any] = ["hid": modifierState(.hidSystemState), "combined": modifierState(.combinedSessionState),
    "private": ["queried": false, "available": false, "reason": "privateState has no global flags query; a dedicated event-source instance is required"]]
var apps = [[String: Any]]()
for app in running {
    axErrors.removeAll()
    let skipAX = fastWindowOnly || app.bundleIdentifier == fixtureBundle
    phase(skipAX ? "skip-AX-" + (app.bundleIdentifier ?? "") : "collector-AXWindows")
    let ax: (nodes: [[String: Any]], truncated: Bool) = skipAX ? ([], false) : tree(AXUIElementCreateApplication(app.processIdentifier))
    var metadata: [String: Any] = ["bundle": app.bundleIdentifier ?? "", "name": app.localizedName ?? "", "pid": app.processIdentifier,
        "active": app.isActive, "bundlePath": app.bundleURL?.path ?? "", "executablePath": app.executableURL?.path ?? "",
        "nodes": ax.nodes, "truncated": ax.truncated, "axErrors": axErrors, "axSkipped": skipAX,
        "axSkipReason": fastWindowOnly ? "fast WindowServer/cursor/screens/flags only; no AX query" :
            (app.bundleIdentifier == fixtureBundle ? "fixture AX menu traversal can invoke lazy NSStatusItem.menu delegates; never queried" : "")]
    if !fastWindowOnly {
        metadata["executableSHA256"] = app.executableURL.flatMap { try? Data(contentsOf: $0) }.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? ""
    }
    apps.append(metadata)
}
@_silgen_name("CGSMainConnectionID") func observerConnection() -> UInt32
@_silgen_name("CGSGetWindowCount") func observerWindowCount(_ cid: UInt32, _ target: UInt32, _ count: inout Int32) -> CGError
@_silgen_name("CGSGetProcessMenuBarWindowList") func observerMenuBarWindows(_ cid: UInt32, _ target: UInt32, _ count: Int32, _ list: UnsafeMutablePointer<CGWindowID>, _ outCount: inout Int32) -> CGError
// A separate WindowServer query includes real offscreen status windows, which
// optionAll can omit on modern macOS. No collector cache/command is consulted.
var total: Int32 = 0
let connection = observerConnection()
phase("CGS-window-count")
_ = observerWindowCount(connection, 0, &total)
var menuIDs = [CGWindowID](repeating: 0, count: max(4096, Int(total)))
var menuCount: Int32 = 0
phase("CGS-menu-window-list")
let menuResult = observerMenuBarWindows(connection, 0, Int32(menuIDs.count), &menuIDs, &menuCount)
let actualMenuIDs = menuResult == .success ? Array(menuIDs.prefix(Int(menuCount))) : []
phase("CGWindow-optionAll")
var all = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
phase("CGWindow-menu-descriptions")
let menuDescriptions = CGWindowListCreateDescriptionFromArray(actualMenuIDs.map(NSNumber.init(value:)) as CFArray) as? [[String: Any]] ?? []
let present = Set(all.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue })
all += menuDescriptions.filter { !present.contains(($0[kCGWindowNumber as String] as? NSNumber)?.intValue ?? -1) }
phase("CGWindow-onScreen")
let onscreen = Set((CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue })
let fixturePID = running.first(where: { $0.bundleIdentifier == fixtureBundle })?.processIdentifier
let collectorPID = running.first(where: { $0.bundleIdentifier == collectorBundle })?.processIdentifier
let nativeMenus = Set(actualMenuIDs)
let scoped = all.filter { raw in
    let pid = (raw[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
    let id = (raw[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
    return pid == fixturePID || pid == collectorPID || nativeMenus.contains(id)
}
let windows = scoped.compactMap { raw -> [String: Any]? in
    guard let id = raw[kCGWindowNumber as String] as? NSNumber,
          let rect = raw[kCGWindowBounds as String] as? [String: Any],
          let frame = CGRect(dictionaryRepresentation: rect as CFDictionary) else { return nil }
    return ["id": id, "pid": raw[kCGWindowOwnerPID as String] ?? 0, "owner": raw[kCGWindowOwnerName as String] ?? "",
            "name": raw[kCGWindowName as String] ?? "", "layer": raw[kCGWindowLayer as String] ?? 0,
            "alpha": raw[kCGWindowAlpha as String] ?? -1, "onScreen": onscreen.contains(id.intValue), "frame": rectangle(frame)]
}
let sourceNativeWindows = windows.filter { window in
    guard let name = window["name"] as? String else { return false }
    return name.range(of: "^Fixture-[0-9]+$", options: .regularExpression) != nil &&
           (window["layer"] as? NSNumber)?.intValue == Int(CGWindowLevelForKey(.statusWindow))
}
var fixtureState: [String: Any] = [:]
if let fixtureStatePath, let data = try? Data(contentsOf: URL(fileURLWithPath: fixtureStatePath)), data.count <= 8_388_608,
   let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { fixtureState = value }
let fixtureReceiptMatchesPID = (fixtureState["pid"] as? NSNumber)?.int32Value == fixturePID
phase("CGEvent-cursor")
let cursor = CGEvent(source: nil)?.location
phase("NSScreen-metadata")
let screens = NSScreen.screens.compactMap { screen -> [String: Any]? in
    guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
    return ["displayID": id, "frameQuartz": rectangle(CGDisplayBounds(id)),
            "frameAppKit": rectangle(screen.frame), "visibleFrameAppKit": rectangle(screen.visibleFrame),
            "backingScaleFactor": screen.backingScaleFactor]
}
phase("permission-preflight-and-serialization")
let result: [String: Any] = ["schema": 1, "model": model, "timestamp": Date().timeIntervalSince1970,
                           "cursorQuartz": cursor.map { ["x": $0.x, "y": $0.y] } ?? [:], "screens": screens,
                           "trusted": fastWindowOnly ? NSNull() : AXIsProcessTrusted() as Any,
                           "screenCapture": CGPreflightScreenCaptureAccess(), "fastWindowOnly": fastWindowOnly,
                           "modifierStates": modifierStates,
                           "display": rectangle(display), "frontmostBundle": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
                           "apps": apps, "windows": windows, "sourceNativeWindows": sourceNativeWindows,
                           "fixtureReceiptMatchesPID": fixtureReceiptMatchesPID,
                           "fixtureStatePath": fixtureStatePath ?? "", "menuBarWindowIDs": actualMenuIDs,
                           "menuBarWindowQueryError": menuResult.rawValue,
                           "guards": ["verificationHost": optIn, "expectedModel": fixedModel, "collectorPath": collectorPath, "fixturePath": fixturePath],
                           "source": fastWindowOnly ? "explicit Host WindowServer/cursor/screens/modifier-state only; no AX or input" :
                               "explicit Host read-only collector AXWindows and WindowServer; fixture AX completely skipped; no input"]
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
if let output { try data.write(to: URL(fileURLWithPath: output), options: .atomic) }
else { FileHandle.standardOutput.write(data) }
