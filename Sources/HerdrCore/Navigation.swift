import Foundation

/// Herdr's switching commands (same names as herdr-app's `keys.json`).
public enum Navigation: Equatable, Sendable {
    case tabNext, tabPrev, tabSelect(Int), spaceNext, spacePrev, spaceSelect(Int), agentNext, agentPrev
}

/// What the sidebar shows, in its order: spaces with their tabs' live terminals, then the
/// terminals no tab shows (each its own "tab" in a last group).
public struct NavGroup: Equatable, Sendable {
    public let id: String
    public let tabs: [NavTab]
}

public struct NavTab: Equatable, Sendable {
    public let id: String
    public let terminals: [String]
}

/// Where you were last, per space and per tab, so switching back lands there (as Herdr
/// keeps each tab's focused pane).
public struct NavMemory: Equatable, Sendable {
    public var bySpace: [String: String] = [:]
    public var byTab: [String: String] = [:]
    public init() {}

    /// Terminals in the order they were shown, most recent last (at most 50).
    public private(set) var history: [String] = []

    public mutating func note(_ address: String, in groups: [NavGroup]) {
        history.removeAll { $0 == address }
        history.append(address)
        if history.count > 50 { history.removeFirst(history.count - 50) }
        guard let (g, t) = Navigator.locate(address, in: groups) else { return }
        bySpace[groups[g].id] = address
        byTab[groups[g].tabs[t].id] = address
    }
}

extension NavMemory {
    /// The terminal shown before, skipping `closing` and what isn't live any more: where ⌘W
    /// goes back to, as a browser returns to the tab you came from.
    public func previous(excluding closing: Set<String>, isLive: (String) -> Bool) -> String? {
        history.reversed().first { !closing.contains($0) && isLive($0) }
    }
}

public enum Navigator {
    /// The terminal to select for `nav`, starting from `current`; nil when there's nowhere to go.
    public static func target(_ nav: Navigation, from current: String?, groups: [NavGroup],
                              agents: Set<String>, memory: NavMemory) -> String? {
        // Select N counts as Herdr numbers them (and the sidebar labels them): every tab
        // and space, so one without a live terminal (a mod-only tab) keeps its number and
        // picking it does nothing. Next/previous skip those.
        let all = groups
        let groups = groups
            .map { NavGroup(id: $0.id, tabs: $0.tabs.filter { !$0.terminals.isEmpty }) }
            .filter { !$0.tabs.isEmpty }
        guard !groups.isEmpty else { return nil }
        let here = current.flatMap { locate($0, in: groups) }
        let g = here?.0 ?? 0
        let hereAll = current.flatMap { locate($0, in: all) }

        func land(tab: NavTab) -> String? {
            if let last = memory.byTab[tab.id], tab.terminals.contains(last) { return last }
            return tab.terminals.first
        }
        func land(group: NavGroup) -> String? {
            if let last = memory.bySpace[group.id], locate(last, in: [group]) != nil { return last }
            return group.tabs.first { !$0.terminals.isEmpty }.flatMap(land(tab:))
        }
        func wrap(_ i: Int, _ n: Int) -> Int { ((i % n) + n) % n }

        switch nav {
        case .tabNext, .tabPrev:
            let tabs = groups[g].tabs
            guard let t = here?.1 else { return land(tab: tabs[0]) }
            return land(tab: tabs[wrap(t + (nav == .tabNext ? 1 : -1), tabs.count)])
        case .tabSelect(let n):
            let tabs = all[hereAll?.0 ?? all.firstIndex(where: { $0.id == groups[0].id })!].tabs
            guard n >= 1, n <= tabs.count else { return nil }
            return land(tab: tabs[n - 1])
        case .spaceNext, .spacePrev:
            guard here != nil else { return land(group: groups[0]) }
            return land(group: groups[wrap(g + (nav == .spaceNext ? 1 : -1), groups.count)])
        case .spaceSelect(let n):
            guard n >= 1, n <= all.count else { return nil }
            return land(group: all[n - 1])
        case .agentNext, .agentPrev:
            let order = groups.flatMap { $0.tabs.flatMap(\.terminals) }.filter(agents.contains)
            guard !order.isEmpty else { return nil }
            guard let current, let i = order.firstIndex(of: current) else {
                return nav == .agentNext ? order.first : order.last
            }
            return order[wrap(i + (nav == .agentNext ? 1 : -1), order.count)]
        }
    }

    static func locate(_ address: String, in groups: [NavGroup]) -> (Int, Int)? {
        for (g, group) in groups.enumerated() {
            if let t = group.tabs.firstIndex(where: { $0.terminals.contains(address) }) { return (g, t) }
        }
        return nil
    }
}

/// Herdr's switching keys (herdr-app keys.json), matched as Herdr matches them: by the
/// character the current keyboard layout gives the key without modifiers ("]" on US, so
/// ⌘⇧] works whether the event spells it "]" or "}"; on a layout where that key is "+",
/// ⌘+ stays the terminal's). Tab is matched as `"\t"`.
public enum NavigationKeys {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1), control = Modifiers(rawValue: 2)
        public static let option = Modifiers(rawValue: 4), shift = Modifiers(rawValue: 8)
    }

    static let table: [(String, Modifiers, Navigation)] = [
        ("\t", [.control], .tabNext), ("\t", [.control, .shift], .tabPrev),
        ("]", [.command, .shift], .tabNext), ("[", [.command, .shift], .tabPrev),
        ("]", [.command, .option], .spaceNext), ("[", [.command, .option], .spacePrev),
        ("]", [.command], .agentNext), ("[", [.command], .agentPrev),
    ]

    /// `key`: the layout's character for the key with no modifiers.
    public static func navigation(key: String, modifiers m: Modifiers) -> Navigation? {
        if let hit = table.first(where: { $0.0 == key && $0.1 == m }) { return hit.2 }
        guard key.count == 1, let n = Int(key), (1...9).contains(n) else { return nil }
        if m == [.command] { return .tabSelect(n) }
        if m == [.control] { return .spaceSelect(n) }
        return nil
    }
}
