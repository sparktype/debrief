import Foundation

/// Marker-wrapped TOML MCP table body for Codex / Grok `config.toml`.
enum McpTomlConfig {
    static let begin = "# BEGIN debrief-mcp"
    static let end = "# END debrief-mcp"

    static func upsert(existing: String, fragment: String) -> String {
        let block = "\(begin)\n\(fragment.trimmingCharacters(in: .newlines))\n\(end)\n"
        if let range = existing.range(of: #"\#(begin)[\s\S]*?\#(end)\n?"#, options: .regularExpression) {
            return existing.replacingCharacters(in: range, with: block)
        }
        var base = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.isEmpty { base += "\n\n" }
        return base + block
    }

    static func removeOwned(_ existing: String) -> String {
        existing.replacingOccurrences(
            of: #"\#(begin)[\s\S]*?\#(end)\n?"#,
            with: "",
            options: .regularExpression
        )
    }

    /// Inner fragment between ownership markers, if present.
    static func ownedFragment(in existing: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"\#(begin)\n([\s\S]*?)\n\#(end)"#,
            options: []
        ) else { return nil }
        let ns = existing as NSString
        guard let match = regex.firstMatch(in: existing, options: [], range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: existing)
        else { return nil }
        return String(existing[range])
    }

    static func hasMarkers(_ existing: String) -> Bool {
        existing.contains(begin) && existing.contains(end)
    }

    static func hasDebriefTable(_ existing: String) -> Bool {
        existing.range(of: #"\[mcp_servers\.debrief\]"#, options: .regularExpression) != nil
    }
}
