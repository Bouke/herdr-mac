import Foundation

/// What an agent says it's doing (OSC 7501), most urgent first.
public enum AgentState: String, Sendable, Comparable, CaseIterable {
    case blocked, done, working, idle

    var urgency: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (a: Self, b: Self) -> Bool { a.urgency < b.urgency }
}

public struct CoreTerminal: Identifiable, Sendable, Equatable {
    public var raw: JSON
    public init(_ raw: JSON) { self.raw = raw }

    public var id: String { address }
    public var address: String { raw["address"].string ?? "?" }
    public var isLive: Bool { raw["state"].string == "live" }
    public var title: String? { raw["title"].string.flatMap { $0.isEmpty ? nil : $0 } }
    public var cwd: String? { raw["foreground"]["cwd"].string ?? raw["cwd"].string }
    public var program: String? { raw["foreground"]["name"].string ?? raw["argv"].array?.first?.string.map { ($0 as NSString).lastPathComponent } }
    public var agentApp: String? { raw["status"]["app"].string }
    public var agentState: AgentState? { raw["status"]["state"].string.flatMap(AgentState.init(rawValue:)) }
    public var parent: String? { raw["parent"].string }
    public var turn: Int? { raw["turn"].int }
    /// The turn someone last looked at, on any Herdr client (`herdr.seen`).
    public var seenTurn: Int? { label("herdr.seen").flatMap(Int.init) }

    /// The state as Herdr shows it: "done" means finished while nobody was looking, so a
    /// done turn that was seen is idle again.
    public var shownState: AgentState? {
        guard agentState == .done, let turn, let seen = seenTurn, seen >= turn else { return agentState }
        return .idle
    }

    /// Looking at it now would clear its "done" (Herdr records the seen turn).
    public var needsSeen: Bool { agentState == .done && shownState == .done }
    public func label(_ key: String) -> String? { raw["labels"][key].string }

    static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu", "pwsh",
                                      "powershell", "xonsh", "elvish", "login"]

    /// Only a shell runs in it (at its prompt): closing it loses nothing. As Herdr's
    /// `program.shell`; an agent that reported a status is never "just a shell".
    public var isShell: Bool {
        guard agentApp == nil, let p = program else { return agentApp == nil }
        return Self.shells.contains(p.hasPrefix("-") ? String(p.dropFirst()) : p)
    }

    /// A short name for a list row: the title a program set, else what runs in it.
    public var displayName: String { title ?? program ?? address }
}

public struct SpaceTab: Identifiable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var index: Int
    /// Terminal addresses in the tab's split tree, left-to-right / top-to-bottom.
    public var terminals: [String]
    public var displayName: String { name.isEmpty ? "\(index + 1)" : name }
}

public struct Space: Identifiable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var folder: String?
    public var machine: String?
    public var tabs: [SpaceTab]
}

/// A tab this app started, not yet in Herdr's document.
public struct PendingTab: Equatable, Sendable {
    public let space: String
    public let folder: String?
    public let tab: SpaceTab
    public init(space: String, folder: String?, tab: SpaceTab) { self.space = space; self.folder = folder; self.tab = tab }
}

/// Herdr's spaces and tabs, from the `herdr-app` core document.
public enum HerdrDocument {
    public static let name = "herdr-app"

    public static func spaces(from value: JSON) -> [Space] {
        (value["spaces"].array ?? []).compactMap { s in
            guard let id = s["id"].string else { return nil }
            let tabs = (s["tabs"].array ?? []).enumerated().compactMap { i, t -> SpaceTab? in
                guard let tid = t["id"].string else { return nil }
                var addresses: [String] = []
                collect(t["root"], into: &addresses)
                return SpaceTab(id: tid, name: t["name"].string ?? "", index: i, terminals: addresses)
            }
            return Space(id: id, name: s["name"].string ?? "", folder: s["folder"].string,
                         machine: s["machine"].string, tabs: tabs)
        }
    }

    static func collect(_ node: JSON, into out: inout [String]) {
        if let t = node["content"]["terminal"].string { out.append(t) }
        for child in node["children"].array ?? [] { collect(child, into: &out) }
    }

    /// The document's spaces with tabs this app started that Herdr hasn't written yet:
    /// appended to their space (numbered after its tabs), or as a new space at the end.
    public static func merge(_ spaces: [Space], pending: [PendingTab]) -> [Space] {
        var out = spaces
        for p in pending where !out.contains(where: { $0.tabs.contains { $0.id == p.tab.id } }) {
            if let i = out.firstIndex(where: { $0.id == p.space }) {
                var tab = p.tab
                tab.index = out[i].tabs.count
                out[i].tabs.append(tab)
            } else {
                out.append(Space(id: p.space, name: "", folder: p.folder, machine: nil, tabs: [p.tab]))
            }
        }
        return out
    }

    /// Tabs for live terminals that carry Herdr's `herdr.space`/`herdr.tab` labels but that
    /// no tab of the document holds: Herdr shows such a terminal there ("a terminal with
    /// those labels shows up there"), so they keep their space after a restart even while
    /// herdr-app isn't running to write them into its document. Oldest terminal first.
    public static func labelledTabs(_ terminals: [CoreTerminal], placed: Set<String>) -> [PendingTab] {
        var tabs: [PendingTab] = []
        for t in terminals.filter(\.isLive).sorted(by: { ($0.raw["created_ms"].double ?? 0) < ($1.raw["created_ms"].double ?? 0) })
        where !placed.contains(t.address) {
            guard let space = t.label("herdr.space"), let tab = t.label("herdr.tab") else { continue }
            if let i = tabs.firstIndex(where: { $0.tab.id == tab }) {
                var p = tabs[i].tab
                p.terminals.append(t.address)
                tabs[i] = PendingTab(space: tabs[i].space, folder: tabs[i].folder, tab: p)
            } else {
                tabs.append(PendingTab(space: space, folder: t.cwd, tab: SpaceTab(id: tab, name: "", index: 0, terminals: [t.address])))
            }
        }
        return tabs
    }

    /// New ids in Herdr's shape (`sp…` / `tb…` + 32 hex), so herdr-app adopts them.
    public static func newId(_ prefix: String) -> String {
        prefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
