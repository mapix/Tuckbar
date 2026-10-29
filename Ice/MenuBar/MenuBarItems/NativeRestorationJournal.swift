// MacMenuY contributors — GPL-3.0; see LICENSE and NOTICE.md.
import Foundation
import CoreGraphics

/// Local recovery evidence for movements made by this collector only. Source
/// identities are never guessed from an unrelated reused WindowServer number.
struct NativeRestorationIdentity: Codable, Equatable {
    var namespace: String
    var title: String
    var windowID: UInt32
    var key: String { namespace + ":" + title }
    var isStable: Bool { !namespace.isEmpty && !namespace.hasPrefix("unresolved.") && !namespace.hasPrefix("pid.") }
}
struct NativeRestorationRect: Codable, Equatable {
    var x: Double; var y: Double; var width: Double; var height: Double
    init(_ rect: CGRect) { x=rect.minX;y=rect.minY;width=rect.width;height=rect.height }
    var rect: CGRect { CGRect(x:x,y:y,width:width,height:height) }
    var valid: Bool { [x,y,width,height].allSatisfy(\.isFinite) && width>0 && height>0 && width<1_000_000 && height<10_000 }
}
struct NativeRestorationJournalEntry: Codable, Equatable, Identifiable {
    enum Side: String, Codable { case left, right }
    var id: UUID
    var item: NativeRestorationIdentity
    var target: NativeRestorationIdentity
    var side: Side
    var section: String
    var sourceBundleID: String?
    var menuBand: NativeRestorationRect
    var originalFrame: NativeRestorationRect?
    var originalOrder: [NativeRestorationIdentity]
    var originalOnScreen: Bool?
    var recordedAt: TimeInterval
    var valid: Bool {
        !item.namespace.isEmpty && item.namespace.count<1024 && item.title.count<2048 &&
        target.namespace.count<1024 && target.title.count<2048 &&
        ["visible", "hidden", "alwaysHidden"].contains(section) && menuBand.valid &&
        (originalFrame?.valid ?? true) && originalOrder.count<=4096 && recordedAt.isFinite
    }
}
final class NativeRestorationJournalStore {
    static let key="MacMenuY.NativeRestorationJournal.v1"
    private let defaults: UserDefaults
    private(set) var error: String?
    private struct Snapshot: Codable { var version: Int; var entries: [NativeRestorationJournalEntry] }
    init(defaults: UserDefaults = .standard) { self.defaults=defaults }
    func load() -> [NativeRestorationJournalEntry] {
        guard let data=defaults.data(forKey:Self.key) else { return [] }
        guard data.count<=8_388_608,
              let snapshot=try? JSONDecoder().decode(Snapshot.self,from:data),snapshot.version==1,
              snapshot.entries.count<=4096,snapshot.entries.allSatisfy(\.valid) else {
            // Preserve malformed evidence rather than silently replacing it.
            defaults.set(data,forKey:Self.key+".invalid")
            error="上次恢复记录无法读取，原始记录已保留。"
            return []
        }
        error=nil
        return snapshot.entries
    }
    @discardableResult func save(_ entries: [NativeRestorationJournalEntry]) -> Bool {
        guard entries.count<=4096,entries.allSatisfy(\.valid),
              let data=try? JSONEncoder().encode(Snapshot(version:1,entries:entries)) else {
            error="无法保存菜单栏恢复记录。";return false
        }
        if entries.isEmpty { defaults.removeObject(forKey:Self.key) }
        else { defaults.set(data,forKey:Self.key) }
        error=nil;return true
    }
}
