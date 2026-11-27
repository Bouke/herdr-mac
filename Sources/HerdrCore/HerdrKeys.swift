import Foundation

/// The person's Herdr key bindings (`~/.config/herdr-app/keys.json`, the file herdr-app
/// reads). Its `send:<text>` bindings (type text into the terminal: ⌥⌫ deletes a word,
/// ⌘← goes to the line start...) become Ghostty keybindings, so they work here too.
public struct HerdrKeys: Equatable, Sendable {
    public var raw: JSON
    public init(_ raw: JSON = [:]) { self.raw = raw }

    /// herdr-app's keys.json; `HERDR_MAC_KEYS` points elsewhere (for testing).
    public static let defaultURL = ProcessInfo.processInfo.environment["HERDR_MAC_KEYS"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/herdr-app/keys.json")

    public static func load(_ url: URL = defaultURL) -> HerdrKeys { read(url) ?? HerdrKeys() }

    /// nil for an existing file that isn't valid (half-written): keep the last good keys.
    public static func read(_ url: URL = defaultURL) -> HerdrKeys? {
        guard let data = try? Data(contentsOf: url) else {
            return FileManager.default.fileExists(atPath: url.path) ? nil : HerdrKeys()
        }
        guard let json = try? JSON.parse(data), json.object != nil else { return nil }
        return HerdrKeys(json)
    }

    /// Ghostty `keybind` lines for every `send:` binding in `global` and `terminal`
    /// (`terminal` wins, as in Herdr). Keys Ghostty can't name are skipped.
    public func ghosttyKeybinds() -> [String] {
        var binds: [String: String] = [:]
        for section in ["global", "terminal"] {
            for (key, action) in raw[section].object ?? [:] {
                guard let action = action.string, action.hasPrefix("send:"), let trigger = Self.trigger(key) else { continue }
                binds[trigger] = "text:" + Self.escape(String(action.dropFirst(5)))
            }
        }
        return binds.keys.sorted().map { "keybind = \($0)=\(binds[$0]!)" }
    }

    /// Herdr's "alt-backspace" → Ghostty's "alt+backspace" (cmd is super).
    static func trigger(_ key: String) -> String? {
        var parts = key.lowercased().split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        // "cmd--" is ⌘ and the minus key.
        if parts.count >= 2, parts.last == "", parts[parts.count - 2] == "" { parts.removeLast(2); parts.append("-") }
        guard let last = parts.popLast(), !last.isEmpty else { return nil }
        var out: [String] = []
        for m in parts {
            switch m {
            case "cmd", "super": out.append("super")
            case "ctrl", "control": out.append("ctrl")
            case "alt", "opt", "option": out.append("alt")
            case "shift": out.append("shift")
            default: return nil
            }
        }
        let names = ["pageup": "page_up", "pagedown": "page_down", "esc": "escape", "return": "enter", "del": "delete",
                     "-": "minus", "=": "equal", "[": "bracket_left", "]": "bracket_right", ",": "comma", ".": "period",
                     "/": "slash", ";": "semicolon", "'": "apostrophe", "`": "backquote", "\\": "backslash"]
        let k = names[last] ?? last
        guard k.count == 1 || ["backspace", "delete", "left", "right", "up", "down", "home", "end", "page_up", "page_down",
                                "enter", "escape", "tab", "space", "minus", "equal", "bracket_left", "bracket_right",
                                "comma", "period", "slash", "semicolon", "apostrophe", "backquote", "backslash"].contains(k)
                || (k.hasPrefix("f") && Int(k.dropFirst()) != nil) else { return nil }
        return (out + [k]).joined(separator: "+")
    }

    /// Text for Ghostty's `text:` action (Zig string escapes).
    static func escape(_ s: String) -> String {
        s.unicodeScalars.map { u in
            switch u {
            case "\\": return "\\\\"
            case "\"": return "\\\""
            case _ where u.value < 0x20 || u.value == 0x7f: return String(format: "\\x%02x", u.value)
            case _ where u.value > 0x7e: return "\\u{\(String(u.value, radix: 16))}"
            default: return String(u)
            }
        }.joined()
    }
}
