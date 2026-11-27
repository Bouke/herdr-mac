import Foundation

/// Herdr mods are ES modules (`import { div } from "gpui-kit"`, `export default class`).
/// JavaScriptCore's plain script API has no module loader, so a mod's source is rewritten
/// into a function `(__exports, __import) => __exports` that the mod host calls.
public enum ModSource {
    public static func wrap(_ source: String, url: String) -> String {
        var code = source
        var exported: [String] = []

        func replace(_ pattern: String, _ transform: ([String]) -> String) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
            let ns = code as NSString
            var out = ""
            var last = 0
            for m in re.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let groups = (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
                out += transform(groups)
                last = m.range.location + m.range.length
            }
            out += ns.substring(from: last)
            code = out
        }

        // import { a, b as c } from "x";
        replace(#"^[ \t]*import\s*\{([^}]*)\}\s*from\s*["']([^"']+)["'];?"#) { g in
            "const {\(bindings(g[1]))} = __import(\(quote(g[2])));"
        }
        // import d, { a } from "x";
        replace(#"^[ \t]*import\s+([A-Za-z_$][\w$]*)\s*,\s*\{([^}]*)\}\s*from\s*["']([^"']+)["'];?"#) { g in
            "const \(g[1]) = __import(\(quote(g[3]))).default; const {\(bindings(g[2]))} = __import(\(quote(g[3])));"
        }
        // import * as n from "x";
        replace(#"^[ \t]*import\s*\*\s*as\s+([A-Za-z_$][\w$]*)\s*from\s*["']([^"']+)["'];?"#) { g in
            "const \(g[1]) = __import(\(quote(g[2])));"
        }
        // import d from "x";
        replace(#"^[ \t]*import\s+([A-Za-z_$][\w$]*)\s+from\s*["']([^"']+)["'];?"#) { g in
            "const \(g[1]) = __import(\(quote(g[2]))).default;"
        }
        // import "x";
        replace(#"^[ \t]*import\s*["']([^"']+)["'];?"#) { g in "__import(\(quote(g[1])));" }
        // export default ...
        replace(#"^([ \t]*)export\s+default\s+"#) { g in "\(g[1])__exports.default = " }
        // export const|let|var|function|async function|class name
        replace(#"^([ \t]*)export\s+(const|let|var|function\*?|async\s+function|class)\s+([A-Za-z_$][\w$]*)"#) { g in
            exported.append(g[3])
            return "\(g[1])\(g[2]) \(g[3])"
        }
        // export { a, b as c };
        var lists: [String] = []
        replace(#"^[ \t]*export\s*\{([^}]*)\};?"#) { g in
            lists.append(g[1])
            return ""
        }
        let tail = exported.map { "__exports.\($0) = \($0);" }
            + lists.flatMap { list in
                list.split(separator: ",").compactMap { item -> String? in
                    let parts = item.split(separator: " ").filter { !$0.isEmpty }.map(String.init)
                    guard let local = parts.first else { return nil }
                    let name = parts.count == 3 && parts[1] == "as" ? parts[2] : local
                    return "__exports.\(name) = \(local);"
                }
            }
        return "(function (__exports, __import) {\n\(code)\n\(tail.joined(separator: "\n"))\nreturn __exports;\n})\n//# sourceURL=\(url)"
    }

    /// `a, b as c` → `a, b: c` (destructuring).
    static func bindings(_ list: String) -> String {
        list.split(separator: ",").map { item in
            let parts = item.split(separator: " ").filter { !$0.isEmpty }
            return parts.count == 3 && parts[1] == "as" ? "\(parts[0]): \(parts[2])" : parts.joined()
        }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    static func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
}
