import AppKit
import HerdrCore
import Observation

/// What mods see of herdr-mac, in the shapes of Herdr's `herdr.d.ts`: spaces, tabs, panes,
/// agents, the focused terminal, Herdr's shared state and layout. One per app.
@MainActor @Observable
final class ModHost {
    static let appHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/herdr-app")

    /// Bumped when something mods read changed outside the store (shared state, branches).
    private(set) var version = 0

    @ObservationIgnored var store: HerdrStore?
    @ObservationIgnored var dark = true
    /// The terminal the window shows (observed: mods re-render when it changes).
    var selection: String?
    /// Shows a terminal (selects it in the window).
    @ObservationIgnored var select: ((String) -> Void)?

    @ObservationIgnored private var herdrShared: [String: JSON] = [:]
    @ObservationIgnored private var localShared: [String: JSON] = [:]
    @ObservationIgnored private var sharedWatcher: FileWatcher?
    @ObservationIgnored private var branches: [String: (branch: String?, at: Date)] = [:]
    @ObservationIgnored private var branchPending: Set<String> = []

    init() {
        loadShared()
        sharedWatcher = FileWatcher(Self.appHome.appendingPathComponent("shared.json")) { [weak self] in
            MainActor.assumeIsolated { self?.loadShared(); self?.version += 1 }
        }
    }

    /// A mod's title from its mod.json, else its folder name.
    static func title(_ mod: String) -> String {
        let url = appHome.appendingPathComponent("mods/\(mod)/mod.json")
        return (try? Data(contentsOf: url)).flatMap { try? JSON.parse($0) }?["title"].string ?? mod
    }

    /// Mods in `mods/` that have a view.
    static func mods() -> [String] {
        let dir = appHome.appendingPathComponent("mods")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent("\($0)/main.js").path) }.sorted()
    }

    // MARK: Shared state

    /// Herdr's shared state is read live but never written: herdr-app owns shared.json.
    /// A mod's `setShared` here stays in this app.
    private func loadShared() {
        let url = Self.appHome.appendingPathComponent("shared.json")
        guard let data = try? Data(contentsOf: url), let json = try? JSON.parse(data), let o = json.object else { return }
        herdrShared = o
    }

    func shared(_ key: String) -> JSON { localShared[key] ?? herdrShared[key] ?? .null }

    func setShared(_ key: String, _ value: JSON) {
        localShared[key] = value
        version += 1
    }

    // MARK: Data

    func data(_ name: String, mod: String) -> JSON {
        switch name {
        case "spaces": spacesJSON()
        case "panes": .array(panesJSON())
        case "agents": .array(agentsJSON())
        case "terminals": .array((store?.liveTerminals ?? []).map(\.raw))
        case "focused": focusedJSON()
        case "theme": ModTheme(dark: dark).json
        case "settings": settingsJSON()
        case "layout": layoutJSON(mod: mod)
        case "props": [:]
        default: .null
        }
    }

    private func where_(_ address: String) -> (Space, SpaceTab)? {
        for s in store?.spaces ?? [] { for t in s.tabs where t.terminals.contains(address) { return (s, t) } }
        return nil
    }

    private var activeSpace: Space? {
        selection.flatMap(where_)?.0 ?? store?.spaces.first
    }

    private func spacesJSON() -> JSON {
        guard let store else { return [] }
        let active = selection.flatMap(where_)
        return .array(store.spaces.enumerated().map { i, s in
            let live = s.tabs.flatMap(\.terminals).filter { store.terminals[$0]?.isLive == true }
            let cwd = live.first.flatMap { store.terminals[$0]?.cwd } ?? s.folder
            return [
                "id": .string(s.id), "index": .number(Double(i)), "name": .string(store.displayName(s)), "named": .bool(!s.name.isEmpty),
                "folder": .string(s.folder ?? cwd ?? ""), "machine": s.machine.map(JSON.string) ?? .null,
                "branch": cwd.flatMap(branch).map(JSON.string) ?? .null,
                "active": .bool(s.id == (active?.0.id ?? store.spaces.first?.id)),
                "status": store.state(of: s.tabs.flatMap(\.terminals)).map { .string($0.rawValue) } ?? .null,
                "tabs": .array(s.tabs.map { t in
                    let liveTab = t.terminals.filter { store.terminals[$0]?.isLive == true }
                    return [
                        "id": .string(t.id), "index": .number(Double(t.index)), "name": .string(t.displayName), "named": .bool(!t.name.isEmpty),
                        "active": .bool(t.id == active?.1.id), "status": store.state(of: liveTab).map { .string($0.rawValue) } ?? .null,
                        "panes": .number(Double(liveTab.count)), "zoomed": false, "settled": false,
                        "settled_at": .null, "changed_at": .null, "working_since": .null,
                    ]
                }),
            ]
        })
    }

    private func program(_ t: CoreTerminal) -> JSON {
        ["name": .string(t.agentApp ?? t.program ?? "program"), "shell": .bool(t.isShell)]
    }

    private func panesJSON() -> [JSON] {
        guard let store else { return [] }
        return store.spaces.flatMap { s in
            s.tabs.flatMap { tab in
                tab.terminals.compactMap { address -> JSON? in
                    guard let t = store.terminals[address], t.isLive else { return nil }
                    return [
                        "pane": .string("pane:\(address)"), "terminal": .string(address), "tab": .string(tab.id), "space": .string(s.id),
                        "title": .string(t.displayName), "name": .null, "cwd": t.cwd.map(JSON.string) ?? .null,
                        "branch": t.cwd.flatMap(branch).map(JSON.string) ?? .null,
                        "status": t.shownState.map { .string($0.rawValue) } ?? .null, "app": t.agentApp.map(JSON.string) ?? .null,
                        "program": program(t), "focused": .bool(address == selection), "zoomed": false, "movable": false,
                    ]
                }
            }
        }
    }

    private func agentsJSON() -> [JSON] {
        guard let store else { return [] }
        return store.spaces.flatMap { s in
            s.tabs.flatMap { tab in
                tab.terminals.compactMap { address -> JSON? in
                    guard let t = store.terminals[address], t.isLive, let state = t.shownState else { return nil }
                    return [
                        "address": .string(address), "pane": .string("pane:\(address)"), "space": .string(s.id),
                        "space_name": .string(store.displayName(s)), "tab": .string(tab.id), "tab_index": .number(Double(tab.index)),
                        "tab_name": .string(tab.displayName), "status": .string(state.rawValue), "app": t.agentApp.map(JSON.string) ?? .null,
                        "program": program(t), "title": .string(t.displayName), "pane_name": .null, "seq": .number(Double(t.turn ?? 0)),
                        "pinned": .bool(t.label("herdr.pinned") != nil), "focused": .bool(address == selection),
                    ]
                }
            }
        }
    }

    private func focusedJSON() -> JSON {
        guard let selection, let t = store?.terminals[selection] else { return .null }
        let w = where_(selection)
        return [
            "space": w.map { .string($0.0.id) } ?? .null, "tab": w.map { .string($0.1.id) } ?? .null,
            "pane": .string("pane:\(selection)"), "terminal": .string(selection), "cwd": t.cwd.map(JSON.string) ?? .null,
            "agent": t.agentApp != nil ? .string(selection) : .null, "shown": .string(selection),
        ]
    }

    private func settingsJSON() -> JSON {
        var s = HerdrSettings.load().raw
        s["dark"] = .bool(dark)
        s["zoom"] = s["zoom"].isNull ? 1 : s["zoom"]
        return s
    }

    /// The person's Herdr layout (the one herdr-app shows), with the stack and panel that
    /// hold this mod shown: a mod that checks whether it's visible finds itself visible.
    private func layoutJSON(mod: String) -> JSON {
        let name = herdrShared["layout"]?.string ?? "main"
        let url = Self.appHome.appendingPathComponent("layouts/\(name).json")
        guard let data = try? Data(contentsOf: url), var root = try? JSON.parse(data) else {
            return ["id": "herdr-mac", "type": "block", "content": ["mod": .string(mod)]]
        }
        _ = Self.show(&root, mod: mod)
        return root
    }

    private static func show(_ node: inout JSON, mod: String) -> Bool {
        if node["content"]["mod"].string == mod { node["hidden"] = false; return true }
        guard var kids = node["children"].array else { return false }
        for i in kids.indices where show(&kids[i], mod: mod) {
            node["children"] = .array(kids)
            node["hidden"] = false
            if node["type"].string == "stack", let id = kids[i]["id"].string { node["active"] = .string(id) }
            return true
        }
        return false
    }

    // MARK: Git branches (Herdr gives panes theirs)

    private func branch(_ cwd: String) -> String? {
        let cached = branches[cwd]
        if cached == nil || Date().timeIntervalSince(cached!.at) > 15, !branchPending.contains(cwd) {
            branchPending.insert(cwd)
            Task.detached {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                p.arguments = ["-C", cwd, "branch", "--show-current"]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                try? p.run()
                p.waitUntilExit()
                let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let branch = p.terminationStatus == 0 && !text.isEmpty ? text : nil
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    let changed = self.branches[cwd]?.branch != branch || self.branches[cwd] == nil
                    self.branches[cwd] = (branch, Date())
                    self.branchPending.remove(cwd)
                    if changed { self.version += 1 }
                }
            }
        }
        return cached?.branch
    }

    // MARK: Commands

    /// Herdr's command names; the ones herdr-mac can do so far.
    func run(_ name: String, _ args: JSON, log: (String) -> Void) {
        guard let store else { return }
        switch name {
        case "tab.select":
            let space = activeSpace
            let tab = args["id"].string.flatMap { id in store.spaces.flatMap(\.tabs).first { $0.id == id } }
                ?? args["index"].int.flatMap { i in space?.tabs.indices.contains(i - 1) == true ? space?.tabs[i - 1] : nil }
            if let t = tab?.terminals.first(where: { store.terminals[$0]?.isLive == true }) { select?(t) }
        case "agent.focus", "terminal.show", "pane.focus":
            if let t = args["terminal"].string ?? args["pane"].string?.replacingOccurrences(of: "pane:", with: "") { select?(t) }
        case "space.select":
            let space = args["id"].string.flatMap { id in store.spaces.first { $0.id == id } }
                ?? args["index"].int.flatMap { i in store.spaces.indices.contains(i - 1) ? store.spaces[i - 1] : nil }
            if let t = space?.tabs.flatMap(\.terminals).first(where: { store.terminals[$0]?.isLive == true }) { select?(t) }
        case "layout.resize", "layout.select", "layout.show", "layout.hide", "layout.toggle":
            break // Herdr's layout: no meaning in herdr-mac's window
        default:
            log("herdr-mac can't do \(name) yet")
        }
    }
}
