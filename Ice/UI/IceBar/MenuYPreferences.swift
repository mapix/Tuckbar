import SwiftUI

@MainActor final class MenuYPreferences: ObservableObject {
    @Published var opacity: Double {
        didSet {
            let valid = MenuYStoredPreferences.validOpacity(opacity)
            if opacity != valid { opacity = valid; return }
            save()
        }
    }
    @Published var iconSize: Double {
        didSet {
            let valid = MenuYStoredPreferences.validIconSize(iconSize)
            if iconSize != valid { iconSize = valid; return }
            save()
        }
    }
    @Published var style: MenuYBarStyle { didSet { save() } }
    @Published var sortMode: MenuYSortMode { didSet { save() } }
    @Published var rules: [MenuYSortRule] {
        didSet {
            let valid = MenuYStoredPreferences.validRules(rules)
            if rules != valid { rules = valid; return }
            save()
        }
    }
    @Published var activityEnabled: Bool { didSet { save() } }
    @Published var hoverEnterDelay: Double {
        didSet {
            let valid = MenuYStoredPreferences.validEnterDelay(hoverEnterDelay)
            if hoverEnterDelay != valid { hoverEnterDelay = valid; return }
            save()
        }
    }
    @Published var hoverLeaveDelay: Double {
        didSet {
            let valid = MenuYStoredPreferences.validLeaveDelay(hoverLeaveDelay)
            if hoverLeaveDelay != valid { hoverLeaveDelay = valid; return }
            save()
        }
    }
    @Published var ignoredApps: Set<String> { didSet { save() } }
    @Published var lastUsed: [String: Double] {
        didSet {
            let valid = MenuYStoredPreferences.validHistory(lastUsed)
            if lastUsed != valid { lastUsed = valid; return }
            save()
        }
    }
    private let defaults: UserDefaults
    static let storageKey = "MacMenuY.Preferences.v2"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let value = defaults.data(forKey: Self.storageKey).flatMap { try? JSONDecoder().decode(MenuYStoredPreferences.self, from: $0) } ?? MenuYStoredPreferences()
        opacity = value.opacity; iconSize = value.iconSize; style = value.style; sortMode = value.sortMode
        rules = value.rules; activityEnabled = value.activityEnabled
        hoverEnterDelay = value.hoverEnterDelay; hoverLeaveDelay = value.hoverLeaveDelay
        ignoredApps = value.ignoredApps; lastUsed = value.lastUsed
    }
    private func save() {
        let value = MenuYStoredPreferences(opacity: opacity, iconSize: iconSize, style: style, sortMode: sortMode,
                                          rules: rules, activityEnabled: activityEnabled,
                                          hoverEnterDelay: hoverEnterDelay, hoverLeaveDelay: hoverLeaveDelay,
                                          ignoredApps: ignoredApps, lastUsed: lastUsed)
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.storageKey) }
    }
    func migrateIdentityKeys(_ migration:[String:String]) {
        var updated=lastUsed
        for (old,new) in migration {
            if let value=updated.removeValue(forKey:old) { updated[new]=max(updated[new] ?? 0,value) }
        }
        if updated != lastUsed { lastUsed=updated }
    }
    func used(_ item: MenuBarItem) { lastUsed[item.info.description] = Date().timeIntervalSince1970 }
    func rulePriority(_ item: MenuBarItem) -> Int {
        rules.filter { MenuYOrdering.matches($0.pattern, name: item.displayName, identifier: item.info.namespace.rawValue) }.map(\.priority).min() ?? Int.max
    }
    func ordered(_ items: [MenuBarItem], hasActivity: (MenuBarItem) -> Bool) -> [MenuBarItem] {
        // ItemCache contains section arrays; native horizontal order is geometric.
        let original = items.enumerated().sorted { left, right in
            if left.element.frame.minX != right.element.frame.minX { return left.element.frame.minX < right.element.frame.minX }
            return left.offset < right.offset
        }.map(\.element)
        let values = original.enumerated().map { index, item in
            MenuYOrderValue(key: item.info.description, name: item.displayName, identifier: item.info.namespace.rawValue,
                            originalIndex: index, hasActivity: hasActivity(item), lastUsed: lastUsed[item.info.description] ?? 0)
        }
        let order = MenuYOrdering.ordered(values, mode: sortMode, rules: rules)
        var keyed = Dictionary(grouping: original, by: { $0.info.description })
        return order.compactMap { value in
            guard var candidates = keyed[value.key], !candidates.isEmpty else { return nil }
            let item = candidates.removeFirst(); keyed[value.key] = candidates; return item
        }
    }
}
