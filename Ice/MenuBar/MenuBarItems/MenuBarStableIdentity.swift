import Foundation

/// Generic status-item titles are not identities. Prefer an app-provided AX
/// identifier; otherwise use a registration slot that never depends on count.
enum MenuBarStableIdentity {
    static func acceptedIdentifier(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("_NS"), !value.hasPrefix("_AX") else { return nil }
        return value
    }
    static func title(rawTitle: String, identifier: String?, slot: Int) -> String {
        guard rawTitle == "Item-0" else { return rawTitle }
        if let identifier = acceptedIdentifier(identifier) {
            let safe = identifier.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: ".-_"))) ?? identifier
            return "Item-0|ax:\(safe)"
        }
        return "Item-0|slot:\(max(0,slot))"
    }
    static func legacyKeys(namespace: String, rawTitle: String, identifier: String?, slot: Int) -> [String] {
        guard rawTitle == "Item-0" else { return [] }
        let key = namespace + ":" + title(rawTitle:rawTitle,identifier:identifier,slot:slot)
        var aliases = [String]()
        if slot == 0 { aliases.append(namespace + ":Item-0") }
        aliases.append(namespace + ":Item-0|slot:\(max(0,slot))")
        return aliases.filter { $0 != key }
    }
    /// Do not migrate an alias that would refer to two different live items.
    static func migrationMap(entries: [(key: String, aliases: [String])]) -> [String:String] {
        var candidates = [String:Set<String>]()
        for entry in entries { for alias in entry.aliases { candidates[alias,default:[]].insert(entry.key) } }
        return candidates.reduce(into:[:]) { result,pair in if pair.value.count == 1 { result[pair.key]=pair.value.first } }
    }
}
