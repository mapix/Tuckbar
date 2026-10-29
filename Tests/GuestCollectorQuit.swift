// MacMenuY contributors — GPL-3.0; see LICENSE and NOTICE.md.
// Public native app termination, restricted to one disposable Guest collector.
import Cocoa
import Darwin
var size: size_t = 0
sysctlbyname("hw.model", nil, &size, nil, 0)
var bytes = [CChar](repeating: 0, count: max(1, size))
let status = sysctlbyname("hw.model", &bytes, &size, nil, 0)
let model = status == 0 ? String(cString: bytes) : ""
guard model.lowercased().hasPrefix("virtualmac") else {
    FileHandle.standardError.write(Data("GuestCollectorQuit refuses non-VirtualMac hardware\n".utf8)); exit(78)
}
let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 2, args[0] == "--bundle-path", args[1].hasPrefix("/tmp/"), args[1].hasSuffix("/MacMenuY.app") else { exit(64) }
let matches = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "io.novarock.MacMenuY" }
guard matches.count == 1, let app = matches.first, app.bundleURL?.path == args[1] else {
    FileHandle.standardError.write(Data("Exact Guest collector process/bundle path is missing or ambiguous\n".utf8)); exit(65)
}
let result: [String: Any] = ["model": model, "pid": app.processIdentifier, "bundle": app.bundleIdentifier ?? "",
                           "bundlePath": app.bundleURL?.path ?? "", "requestedAt": Date().timeIntervalSince1970,
                           "accepted": app.terminate(), "method": "public NSRunningApplication.terminate; no input, no private test interface"]
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
