import Foundation
import HerdrCore
import Observation

/// Where mods show in herdr-mac's window, like the blocks of a Herdr layout:
/// `sidebar` (stacked at the bottom of the sidebar, as Herdr's `usage` block) and `panel`
/// (the inspector on the right, one tab per mod, as Herdr's `panel-body` stack).
///
/// From `~/.config/herdr-app/herdr-mac.json` (`{"sidebar": [...], "panel": [...]}`),
/// reloaded live. Without those: the mods the person's Herdr layout shows in its sidebar and
/// right panel, minus Herdr's own window parts that herdr-mac draws natively and the mods
/// the file lists as `"hidden"` (a person's own window parts, like a custom sidebar).
@MainActor @Observable
final class ModPlaces {
    enum Place: String, CaseIterable { case sidebar, panel }

    private(set) var sidebar: [String] = []
    private(set) var panel: [String] = []
    /// Whether the places come from herdr-mac.json (else from the Herdr layout).
    private(set) var fromFile = false

    static let url = ModHost.appHome.appendingPathComponent("herdr-mac.json")

    /// Herdr's own mods that make up its window (sidebar lists, tab bars, menus, dialogs):
    /// herdr-mac has its own, so they're never placed from the Herdr layout.
    static let windowParts: Set<String> = [
        "workspace-chrome", "workspace-status", "spaces", "agents", "tabs", "terminals-bar", "terminals-pane", "pane",
        "menu", "new-menu", "toast", "peek", "picker", "prompt", "confirm", "help", "win98",
    ]

    /// Mods the person's herdr-mac.json keeps out of herdr-mac (`"hidden"`).
    private(set) var hidden: Set<String> = []

    /// Never offered: Herdr's window parts and the person's hidden mods.
    func isWindowPart(_ mod: String) -> Bool { Self.windowParts.contains(mod) || hidden.contains(mod) }

    @ObservationIgnored private var watcher: FileWatcher?

    init() {
        load()
        watcher = FileWatcher(Self.url) { [weak self] in MainActor.assumeIsolated { self?.load() } }
    }

    func place(of mod: String) -> Place? {
        sidebar.contains(mod) ? .sidebar : panel.contains(mod) ? .panel : nil
    }

    /// Moves a mod (nil: hides it) and writes herdr-mac.json.
    func move(_ mod: String, to place: Place?) {
        sidebar.removeAll { $0 == mod }
        panel.removeAll { $0 == mod }
        switch place {
        case .sidebar: sidebar.append(mod)
        case .panel: panel.append(mod)
        case nil: break
        }
        save()
    }

    private func save() {
        var json: JSON = ["sidebar": .array(sidebar.map(JSON.string)), "panel": .array(panel.map(JSON.string))]
        if !hidden.isEmpty { json["hidden"] = .array(hidden.sorted().map(JSON.string)) }
        // Keep what else the person put there (e.g. "updates").
        if let data = try? Data(contentsOf: Self.url), let old = try? JSON.parse(data), let o = old.object {
            for (k, v) in o where json[k].isNull { json[k] = v }
        }
        let data = (try? JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: json.data()),
                                                options: [.prettyPrinted, .sortedKeys])) ?? json.data()
        try? data.write(to: Self.url, options: .atomic)
        fromFile = true
    }

    private func load() {
        var json: JSON = [:]
        if let data = try? Data(contentsOf: Self.url) {
            // A broken file keeps the places we have (as Herdr keeps the last good layout).
            guard let parsed = try? JSON.parse(data) else { return }
            json = parsed
        }
        hidden = Set((json["hidden"].array ?? []).compactMap(\.string))
        if json["sidebar"].array != nil || json["panel"].array != nil {
            sidebar = (json["sidebar"].array ?? []).compactMap(\.string)
            panel = (json["panel"].array ?? []).compactMap(\.string)
            fromFile = true
        } else {
            (sidebar, panel) = Self.fromHerdrLayout(hidden: hidden)
            fromFile = false
        }
    }

    /// The mods the Herdr layout shows in its sidebar column and its right panel.
    static func fromHerdrLayout(hidden: Set<String>) -> ([String], [String]) {
        let shared = (try? Data(contentsOf: ModHost.appHome.appendingPathComponent("shared.json"))).flatMap { try? JSON.parse($0) }
        let name = shared?["layout"].string ?? "main"
        guard let data = try? Data(contentsOf: ModHost.appHome.appendingPathComponent("layouts/\(name).json")),
              let root = try? JSON.parse(data) else { return ([], []) }
        func mods(_ node: JSON) -> [String] {
            if let m = node["content"]["mod"].string { return node["hidden"].bool == true ? [] : [m] }
            return (node["children"].array ?? []).flatMap(mods)
        }
        func find(_ node: JSON, _ id: String) -> JSON? {
            if node["id"].string == id { return node }
            return (node["children"].array ?? []).lazy.compactMap { find($0, id) }.first
        }
        let sidebar = find(root, "sidebar").map(mods) ?? []
        let panel = (find(root, "panel") ?? find(root, "panel-body")).map(mods) ?? []
        let keep = { (m: String) in !windowParts.contains(m) && !hidden.contains(m) && ModHost.mods().contains(m) }
        return (sidebar.filter(keep), panel.filter(keep))
    }
}
