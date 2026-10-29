// MacMenuY contributors — GPL-3.0; see LICENSE and NOTICE.md.
#if MENUY_VERIFY
import Foundation
import Darwin

/// Fault controls exist only in verification builds and explicitly selected test environments.
/// The skip is consumed after a real fixture movement needs to be returned.
enum NativeRestorationVerification {
    private static var skipped = false
    static var isGuest: Bool {
        guard ProcessInfo.processInfo.arguments.contains("--verification-guest") else { return false }
        var size:size_t=0
        guard sysctlbyname("hw.model",nil,&size,nil,0)==0,size>0,size<4096 else { return false }
        var bytes=[CChar](repeating:0,count:size)
        guard sysctlbyname("hw.model",&bytes,&size,nil,0)==0 else { return false }
        return String(cString:bytes).lowercased().hasPrefix("virtualmac")
    }
    static var isHost: Bool {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--verification-host"),
              let index = args.firstIndex(of: "--verification-host-model"), args.indices.contains(index + 1),
              args[index + 1] == "Mac17,6" else { return false }
        var size: size_t = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0, size < 4096 else { return false }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return false }
        return String(cString: bytes) == args[index + 1]
    }
    static var isAllowed: Bool { isGuest || isHost }
    static func skipReturnOnce(namespace:String)->Bool {
        guard !skipped,isAllowed,namespace=="io.novarock.MacMenuY.Fixture",
              ProcessInfo.processInfo.arguments.contains("--verification-restoration-fail-once") else { return false }
        skipped=true;return true
    }
    static var saveWithoutPrompt:Bool {
        isAllowed && ProcessInfo.processInfo.arguments.contains("--verification-restoration-exit-save")
    }
}
#endif
