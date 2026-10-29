import Foundation
import CoreGraphics

// Model-only stubs let the actual preferences wrapper run without starting a UI.
struct MenuBarItem {
    struct Namespace { let rawValue: String }
    struct Info { let namespace: Namespace; let description: String }
    let info: Info
    let displayName: String
    let frame: CGRect
}

@main struct MenuYPreferencesRuntimeTests {
    @MainActor static func main() throws {
        let name = "io.novarock.MacMenuY.settings-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let p = MenuYPreferences(defaults: defaults)
        precondition(p.opacity == 0.9 && p.iconSize == 24 && p.style == .native)
        p.opacity = .nan
        precondition(p.opacity == 0.9)
        p.opacity = -9
        precondition(p.opacity == 0.4)
        p.opacity = 0.75; p.iconSize = 28; p.style = .glass
        p.sortMode = .activity
        p.rules = [MenuYSortRule(pattern: "app.beta", priority: -2)]
        p.ignoredApps = ["app.music"]
        let restored = MenuYPreferences(defaults: defaults)
        precondition(restored.opacity == 0.75 && restored.iconSize == 28 && restored.style == .glass)
        precondition(restored.rules == p.rules && restored.ignoredApps == ["app.music"])
        let right = MenuBarItem(info: .init(namespace: .init(rawValue: "app.beta"), description: "b"),
                                displayName: "Beta", frame: CGRect(x: 100, y: 0, width: 33, height: 33))
        let left = MenuBarItem(info: .init(namespace: .init(rawValue: "app.alpha"), description: "a"),
                               displayName: "Alpha", frame: CGRect(x: -5000, y: 0, width: 33, height: 33))
        restored.rules = []; restored.sortMode = .original
        precondition(restored.ordered([right,left], hasActivity: { _ in false }).map(\.displayName) == ["Alpha","Beta"])
        restored.rules = [MenuYSortRule(pattern: "app.beta", priority: -1)]
        precondition(restored.ordered([right,left], hasActivity: { _ in false }).map(\.displayName) == ["Beta","Alpha"])
        defaults.set(Data("{broken".utf8), forKey: MenuYPreferences.storageKey)
        let recovered = MenuYPreferences(defaults: defaults)
        precondition(recovered.opacity == 0.9 && recovered.style == .native)
        print("PASS: actual preferences persistence, validation, recovery and stable native-order wrapper")
    }
}
