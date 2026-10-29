// MacMenuY contributors — GPL-3.0; see LICENSE and NOTICE.md.
// Independent, read-only AX / WindowServer observer. Never posts input.
import Cocoa
import ApplicationServices
import Darwin

private func hardwareModel() -> String {
    var size: size_t = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0, size < 4096 else { return "" }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "" }
    return String(cString: bytes)
}
let model = hardwareModel()
guard model.lowercased().hasPrefix("virtualmac") else {
    FileHandle.standardError.write(Data("GuestNativeObserver refuses non-VirtualMac hardware\n".utf8)); exit(78)
}
let args = Array(CommandLine.arguments.dropFirst())
var bundles = Set(["io.novarock.MacMenuY", "io.novarock.MacMenuY.Fixture"])
var output: String?
var requestPermissions = false
var i = 0
while i < args.count {
    if args[i] == "--request-permissions" { requestPermissions = true; i += 1; continue }
    guard i + 1 < args.count else { exit(64) }
    switch args[i] {
    case "--bundle": bundles.insert(args[i + 1])
    case "--output": output = args[i + 1]
    default: exit(64)
    }
    i += 2
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
func tree(_ root: AXUIElement) -> (nodes: [[String: Any]], truncated: Bool) {
    var nodes = [[String: Any]](), visited = [AXUIElement](), budget = 2000
    func walk(_ element: AXUIElement, _ parent: Int?, _ depth: Int, _ relation: String) {
        guard budget > 0, depth < 20, !visited.contains(where: { CFEqual($0, element) }) else { return }
        budget -= 1; visited.append(element); AXUIElementSetMessagingTimeout(element, 0.15)
        let role = attribute(element, "AXRole") as? String ?? ""
        let index = nodes.count
        var node: [String: Any] = ["node": index, "depth": depth, "relation": relation, "role": role]
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
        for relation in ["AXChildren", "AXMenuBar", "AXExtrasMenuBar", "AXWindows", "AXShownMenuUIElement", "AXMenu"] {
            if let children = attribute(element, relation) as? [AXUIElement] {
                for child in children { walk(child, index, depth + 1, relation) }
            } else if let child = attribute(element, relation), CFGetTypeID(child) == AXUIElementGetTypeID() {
                walk(child as! AXUIElement, index, depth + 1, relation)
            }
        }
    }
    walk(root, nil, 0, "root")
    return (nodes, budget == 0)
}
var apps = [[String: Any]]()
for app in NSWorkspace.shared.runningApplications where bundles.contains(app.bundleIdentifier ?? "") {
    let ax = tree(AXUIElementCreateApplication(app.processIdentifier))
    apps.append(["bundle": app.bundleIdentifier ?? "", "name": app.localizedName ?? "", "pid": app.processIdentifier,
                 "active": app.isActive, "bundlePath": app.bundleURL?.path ?? "", "executablePath": app.executableURL?.path ?? "",
                 "nodes": ax.nodes, "truncated": ax.truncated])
}
@_silgen_name("CGSMainConnectionID") func observerConnection() -> UInt32
@_silgen_name("CGSGetWindowCount") func observerWindowCount(_ cid: UInt32, _ target: UInt32, _ count: inout Int32) -> CGError
@_silgen_name("CGSGetProcessMenuBarWindowList") func observerMenuBarWindows(_ cid: UInt32, _ target: UInt32, _ count: Int32, _ list: UnsafeMutablePointer<CGWindowID>, _ outCount: inout Int32) -> CGError
// A separate WindowServer query includes real offscreen status windows, which
// optionAll can omit on modern macOS. No collector cache/command is consulted.
var total: Int32 = 0
let connection = observerConnection()
_ = observerWindowCount(connection, 0, &total)
var menuIDs = [CGWindowID](repeating: 0, count: max(4096, Int(total)))
var menuCount: Int32 = 0
let menuResult = observerMenuBarWindows(connection, 0, Int32(menuIDs.count), &menuIDs, &menuCount)
let actualMenuIDs = menuResult == .success ? Array(menuIDs.prefix(Int(menuCount))) : []
var all = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
let menuDescriptions = CGWindowListCreateDescriptionFromArray(actualMenuIDs.map(NSNumber.init(value:)) as CFArray) as? [[String: Any]] ?? []
let present = Set(all.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue })
all += menuDescriptions.filter { !present.contains(($0[kCGWindowNumber as String] as? NSNumber)?.intValue ?? -1) }
let onscreen = Set((CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue })
let windows = all.compactMap { raw -> [String: Any]? in
    guard let id = raw[kCGWindowNumber as String] as? NSNumber,
          let rect = raw[kCGWindowBounds as String] as? [String: Any],
          let frame = CGRect(dictionaryRepresentation: rect as CFDictionary) else { return nil }
    return ["id": id, "pid": raw[kCGWindowOwnerPID as String] ?? 0, "owner": raw[kCGWindowOwnerName as String] ?? "",
            "name": raw[kCGWindowName as String] ?? "", "layer": raw[kCGWindowLayer as String] ?? 0,
            "alpha": raw[kCGWindowAlpha as String] ?? -1, "onScreen": onscreen.contains(id.intValue), "frame": rectangle(frame)]
}
let cursor = CGEvent(source: nil)?.location
let screens = NSScreen.screens.compactMap { screen -> [String: Any]? in
    guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
    return ["displayID": id, "frameQuartz": rectangle(CGDisplayBounds(id)),
            "frameAppKit": rectangle(screen.frame), "visibleFrameAppKit": rectangle(screen.visibleFrame),
            "backingScaleFactor": screen.backingScaleFactor]
}
let result: [String: Any] = ["schema": 1, "model": model, "timestamp": Date().timeIntervalSince1970,
                           "cursorQuartz": cursor.map { ["x": $0.x, "y": $0.y] } ?? [:], "screens": screens,
                           "trusted": AXIsProcessTrusted(), "screenCapture": CGPreflightScreenCaptureAccess(),
                           "display": rectangle(display), "frontmostBundle": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
                           "apps": apps, "windows": windows, "menuBarWindowIDs": actualMenuIDs,
                           "menuBarWindowQueryError": menuResult.rawValue,
                           "source": "independent read-only Guest process; AXUIElement and CGWindowListCopyWindowInfo"]
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
if let output { try data.write(to: URL(fileURLWithPath: output), options: .atomic) }
else { FileHandle.standardOutput.write(data) }
