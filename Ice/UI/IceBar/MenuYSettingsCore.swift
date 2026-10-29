import Foundation
import CoreGraphics
import CryptoKit

struct MenuYSortRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var pattern: String
    var priority: Int
}

enum MenuYSortMode: String, CaseIterable, Codable {
    case original, alphabetical, activity, recent
    var label: String {
        switch self {
        case .original: "原菜单栏顺序"
        case .alphabetical: "应用名称"
        case .activity: "有提醒的优先"
        case .recent: "最近使用优先"
        }
    }
}

enum MenuYBarStyle: String, CaseIterable, Codable {
    case native, glass, compact
    var label: String {
        switch self {
        case .native: "原生菜单栏"
        case .glass: "玻璃质感"
        case .compact: "紧凑"
        }
    }
}

/// Tolerates additions to the preferences schema without discarding valid
/// settings from an earlier build. Values are validated before the UI uses them.
struct MenuYStoredPreferences: Codable, Equatable {
    static let defaultOpacity = 0.9
    static let defaultIconSize = 24.0
    var opacity = defaultOpacity
    var iconSize = defaultIconSize
    var style = MenuYBarStyle.native
    var sortMode = MenuYSortMode.original
    var rules = [MenuYSortRule]()
    var activityEnabled = true
    var hoverEnterDelay = 0.15
    var hoverLeaveDelay = 0.25
    var ignoredApps = Set<String>()
    var lastUsed = [String: Double]()

    init(opacity: Double = defaultOpacity, iconSize: Double = defaultIconSize,
         style: MenuYBarStyle = .native, sortMode: MenuYSortMode = .original,
         rules: [MenuYSortRule] = [], activityEnabled: Bool = true,
         hoverEnterDelay: Double = 0.15, hoverLeaveDelay: Double = 0.25,
         ignoredApps: Set<String> = [], lastUsed: [String: Double] = [:]) {
        self.opacity = Self.validOpacity(opacity)
        self.iconSize = Self.validIconSize(iconSize)
        self.style = style
        self.sortMode = sortMode
        self.rules = Self.validRules(rules)
        self.activityEnabled = activityEnabled
        self.hoverEnterDelay = Self.validEnterDelay(hoverEnterDelay)
        self.hoverLeaveDelay = Self.validLeaveDelay(hoverLeaveDelay)
        self.ignoredApps = ignoredApps
        self.lastUsed = Self.validHistory(lastUsed)
    }
    private enum CodingKeys: String, CodingKey {
        case opacity, iconSize, style, sortMode, rules, activityEnabled, hoverEnterDelay, hoverLeaveDelay, ignoredApps, lastUsed
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            opacity: (try? c.decode(Double.self, forKey: .opacity)) ?? Self.defaultOpacity,
            iconSize: (try? c.decode(Double.self, forKey: .iconSize)) ?? Self.defaultIconSize,
            style: (try? c.decode(MenuYBarStyle.self, forKey: .style)) ?? .native,
            sortMode: (try? c.decode(MenuYSortMode.self, forKey: .sortMode)) ?? .original,
            rules: (try? c.decode([MenuYSortRule].self, forKey: .rules)) ?? [],
            activityEnabled: (try? c.decode(Bool.self, forKey: .activityEnabled)) ?? true,
            hoverEnterDelay: (try? c.decode(Double.self, forKey: .hoverEnterDelay)) ?? 0.15,
            hoverLeaveDelay: (try? c.decode(Double.self, forKey: .hoverLeaveDelay)) ?? 0.25,
            ignoredApps: (try? c.decode(Set<String>.self, forKey: .ignoredApps)) ?? [],
            lastUsed: (try? c.decode([String: Double].self, forKey: .lastUsed)) ?? [:]
        )
    }
    static func validOpacity(_ n: Double) -> Double { n.isFinite ? min(1, max(0.4, n)) : defaultOpacity }
    static func validIconSize(_ n: Double) -> Double { n.isFinite ? min(36, max(16, n.rounded())) : defaultIconSize }
    static func validEnterDelay(_ n: Double) -> Double { n.isFinite ? min(0.8, max(0.05, (n * 100).rounded() / 100)) : 0.15 }
    static func validLeaveDelay(_ n: Double) -> Double { n.isFinite ? min(1.5, max(0.1, (n * 100).rounded() / 100)) : 0.25 }
    static func validRules(_ input: [MenuYSortRule]) -> [MenuYSortRule] {
        var seen = Set<UUID>()
        return input.prefix(128).filter { seen.insert($0.id).inserted }.map { rule in
            MenuYSortRule(id: rule.id, pattern: String(rule.pattern.prefix(256)), priority: min(999, max(-99, rule.priority)))
        }
    }
    static func validHistory(_ input: [String: Double]) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: input.filter { $0.value.isFinite && $0.value >= 0 }
            .sorted { $0.value > $1.value }.prefix(1000).map { ($0.key, $0.value) })
    }
}

struct MenuYOrderValue: Equatable {
    let key: String
    let name: String
    let identifier: String
    let originalIndex: Int
    let hasActivity: Bool
    let lastUsed: Double
}

enum MenuYOrdering {
    private struct Matcher {
        let regex: NSRegularExpression
        let priority: Int
        func matches(_ value: String) -> Bool {
            regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
        }
    }
    private static func matcher(_ rule: MenuYSortRule) -> Matcher? {
        let text = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let expression = "^" + NSRegularExpression.escapedPattern(for: text)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".") + "$"
        guard let regex = try? NSRegularExpression(pattern: expression, options: [.caseInsensitive]) else { return nil }
        return Matcher(regex: regex, priority: rule.priority)
    }
    static func matches(_ pattern: String, name: String, identifier: String) -> Bool {
        guard let m = matcher(MenuYSortRule(pattern: pattern, priority: 0)) else { return false }
        return m.matches(name) || m.matches(identifier)
    }
    static func priorities(for values: [MenuYOrderValue], rules: [MenuYSortRule]) -> [String: Int] {
        let matchers = rules.compactMap(matcher)
        return Dictionary(values.map { value in
            (value.key, matchers.filter { $0.matches(value.name) || $0.matches(value.identifier) }.map(\.priority).min() ?? Int.max)
        }, uniquingKeysWith: min)
    }
    static func ordered(_ values: [MenuYOrderValue], mode: MenuYSortMode, rules: [MenuYSortRule]) -> [MenuYOrderValue] {
        let priority = priorities(for: values, rules: rules)
        return values.sorted { left, right in
            let lp = priority[left.key] ?? Int.max, rp = priority[right.key] ?? Int.max
            if lp != rp { return lp < rp }
            switch mode {
            case .original: break
            case .alphabetical:
                let result = left.name.localizedStandardCompare(right.name)
                if result != .orderedSame { return result == .orderedAscending }
            case .activity:
                if left.hasActivity != right.hasActivity { return left.hasActivity }
            case .recent:
                if left.lastUsed != right.lastUsed { return left.lastUsed > right.lastUsed }
            }
            return left.originalIndex < right.originalIndex
        }
    }
}

/// Requires an explicit unread/new-message hint and an adjacent count. App
/// names, battery percentages, dates and plain notification counts are not unread.
enum MenuYUnreadHint {
    static func count(_ text: String) -> Int? {
        let patterns = [
            "(?<![A-Za-z0-9+\\-.])([0-9]+)\\s*(?:条|个)?\\s*(?:unread\\b(?:\\s+(?:messages?|notifications?)\\b)?|未读(?:消息)?|new messages?\\b|新消息)",
            "(?:unread\\b(?:\\s+(?:messages?|notifications?)\\b)?|未读(?:消息)?|new messages?\\b|新消息)\\s*[:：]?\\s*\\(?([0-9]+)(?![0-9])"
        ]
        var values = Set<Int>()
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text), let value = Int(text[range]), value <= 99999 else { continue }
                values.insert(value)
            }
        }
        // An AX description that names multiple distinct counts is ambiguous.
        return values.count == 1 ? values.first : nil
    }
}

/// Matches an AX child to its hosted window using current geometry rather than
/// a cached child index. Reordering status items does not change this identity.
enum MenuYHintGeometry {
    static func bestIndex(window: CGRect, children: [CGRect?]) -> Int? {
        guard window.width > 0, window.height > 0 else { return nil }
        let exact = children.enumerated().compactMap { index, frame -> (Int, CGFloat)? in
            guard let frame, frame.width > 0, frame.height > 0 else { return nil }
            let distance = hypot(window.midX - frame.midX, window.midY - frame.midY)
            return distance <= 1 ? (index, distance) : nil
        }.sorted { $0.1 < $1.1 }
        if let first = exact.first {
            if exact.count > 1 && abs(first.1 - exact[1].1) < 0.01 { return nil }
            return first.0
        }
        // Some wide title/music items expose only their icon as the AX frame.
        guard window.width < 1024 else { return nil }
        let candidates = children.enumerated().compactMap { index, frame -> Int? in
            guard let frame, frame.width > 0, frame.height > 0,
                  window.width > frame.width + 24,
                  abs(window.midY - frame.midY) <= 1,
                  window.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return nil }
            return index
        }
        return candidates.count == 1 ? candidates.first : nil
    }
}

/// Visual changes are deliberately a separate signal from confirmed unread.
/// The background is excluded and low color bits are quantized for stability.
enum MenuYVisualFingerprint {
    static func digest(_ image: CGImage) -> Data? {
        guard let context = CGContext(data: nil, width: 48, height: 24, bitsPerComponent: 8,
                                      bytesPerRow: 48 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let raw = context.data else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: 48, height: 24))
        var bytes = Array(UnsafeBufferPointer(start: raw.assumingMemoryBound(to: UInt8.self), count: 48*24*4))
        // Hosted status windows can have an opaque uniform background. Estimate
        // it from the outer corners so wallpaper/theme colors do not become activity.
        let corners = [0, (48-1)*4, (24-1)*48*4, (24*48-1)*4]
        let opaque = corners.filter { bytes[$0+3] > 240 }
        let background: [Int]? = opaque.count == 4 ? (0..<3).map { channel in
            opaque.reduce(0) { $0+Int(bytes[$1+channel]) }/opaque.count
        } : nil
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let backgroundPixel = background.map { color in
                (0..<3).reduce(0) { $0+abs(Int(bytes[index+$1])-color[$1]) } < 40
            } ?? false
            if bytes[index+3] < 16 || backgroundPixel {
                for channel in 0..<4 { bytes[index+channel] = 0 }
            } else {
                for channel in 0..<4 { bytes[index+channel] = bytes[index+channel]/32*32 }
            }
        }
        return Data(SHA256.hash(data: Data(bytes)))
    }
}

/// A failed/unfinished observation is unknown, not a count of zero.
enum MenuYHintObservation: Equatable {
    case confirmed(Int)
    case absent
    case unavailable

    static func completed(text: String) -> Self {
        if let count = MenuYUnreadHint.count(text) { return .confirmed(count) }
        // Explicit unread text with an ambiguous/unsupported count cannot erase
        // a previously confirmed value.
        if text.range(of: "unread\\b|未读|new messages?\\b|新消息", options: [.regularExpression, .caseInsensitive]) != nil {
            return .unavailable
        }
        return .absent
    }
}

struct MenuYHintHistory: Equatable {
    private(set) var values = [String: Int]()
    private(set) var confirmedAt = [String: TimeInterval]()
    private(set) var stale = Set<String>()

    mutating func apply(_ observations: [String: MenuYHintObservation], activeKeys: Set<String>, now: TimeInterval) {
        prune(activeKeys: activeKeys)
        for key in activeKeys {
            switch observations[key] ?? .unavailable {
            case .confirmed(let count):
                guard count >= 0, count <= 99999 else {
                    if values[key] != nil { stale.insert(key) }; continue
                }
                values[key] = count; confirmedAt[key] = now; stale.remove(key)
            case .absent:
                values.removeValue(forKey: key); confirmedAt.removeValue(forKey: key); stale.remove(key)
            case .unavailable:
                // Retain the exact previous confirmation and its age. Never
                // manufacture a zero from a budget cutoff or an AX timeout.
                if values[key] != nil { stale.insert(key) }
            }
        }
    }
    mutating func prune(activeKeys: Set<String>) {
        values = values.filter { activeKeys.contains($0.key) }
        confirmedAt = confirmedAt.filter { activeKeys.contains($0.key) }
        stale.formIntersection(activeKeys)
    }
}
