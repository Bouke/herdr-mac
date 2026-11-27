import Testing
@testable import HerdrCore

private let groups = [
    NavGroup(id: "sp1", tabs: [NavTab(id: "a", terminals: ["t1"]), NavTab(id: "b", terminals: ["t2", "t3"]), NavTab(id: "c", terminals: ["t4"])]),
    NavGroup(id: "sp2", tabs: [NavTab(id: "d", terminals: ["t5"])]),
    NavGroup(id: "loose", tabs: [NavTab(id: "loose:t9", terminals: ["t9"])]),
]

private func go(_ nav: Navigation, _ from: String?, agents: Set<String> = [], memory: NavMemory = NavMemory()) -> String? {
    Navigator.target(nav, from: from, groups: groups, agents: agents, memory: memory)
}

@Test func tabsCycleWithinTheirSpace() {
    #expect(go(.tabNext, "t1") == "t2")
    #expect(go(.tabNext, "t3") == "t4")
    #expect(go(.tabNext, "t4") == "t1")
    #expect(go(.tabPrev, "t1") == "t4")
    #expect(go(.tabNext, "t5") == "t5")
}

@Test func tabSelectCountsFromOneInTheCurrentSpace() {
    #expect(go(.tabSelect(3), "t2") == "t4")
    #expect(go(.tabSelect(1), "t5") == "t5")
    #expect(go(.tabSelect(4), "t1") == nil)
    #expect(go(.tabSelect(0), "t1") == nil)
}

@Test func spacesCycleAndSelectAndRemember() {
    #expect(go(.spaceNext, "t2") == "t5")
    #expect(go(.spaceNext, "t9") == "t1")
    #expect(go(.spacePrev, "t1") == "t9")
    #expect(go(.spaceSelect(2), "t1") == "t5")
    #expect(go(.spaceSelect(9), "t1") == nil)
    var memory = NavMemory()
    memory.note("t3", in: groups)
    #expect(go(.spaceSelect(1), "t5", memory: memory) == "t3")
    #expect(go(.tabNext, "t1", memory: memory) == "t3")
}

@Test func agentsCycleInSidebarOrder() {
    let agents: Set = ["t4", "t2", "t9"]
    #expect(go(.agentNext, "t2", agents: agents) == "t4")
    #expect(go(.agentNext, "t9", agents: agents) == "t2")
    #expect(go(.agentPrev, "t2", agents: agents) == "t9")
    #expect(go(.agentNext, "t1", agents: agents) == "t2")
    #expect(go(.agentNext, "t1") == nil)
}

@Test func nothingSelectedStartsAtTheFirst() {
    #expect(go(.tabNext, nil) == "t1")
    #expect(go(.spaceNext, nil) == "t1")
}

@Test func emptyTabsAndSpacesAreSkipped() {
    let groups = [
        NavGroup(id: "sp1", tabs: [NavTab(id: "a", terminals: ["t1"]), NavTab(id: "gone", terminals: []), NavTab(id: "c", terminals: ["t4"])]),
        NavGroup(id: "empty", tabs: [NavTab(id: "x", terminals: [])]),
        NavGroup(id: "sp2", tabs: [NavTab(id: "d", terminals: ["t5"])]),
    ]
    let go = { (nav: Navigation, from: String) in Navigator.target(nav, from: from, groups: groups, agents: [], memory: NavMemory()) }
    #expect(go(.tabNext, "t1") == "t4")
    #expect(go(.tabSelect(2), "t1") == nil, "Herdr's tab 2 has no terminal")
    #expect(go(.tabSelect(3), "t1") == "t4")
    #expect(go(.spaceNext, "t1") == "t5")
    #expect(go(.spaceSelect(2), "t1") == nil, "Herdr's space 2 has no terminal")
    #expect(go(.spaceSelect(3), "t1") == "t5")
}

@Test func herdrSwitchingKeysByLayoutCharacter() {
    let k = { (key: String, m: NavigationKeys.Modifiers) in NavigationKeys.navigation(key: key, modifiers: m) }
    #expect(k("\t", [.control]) == .tabNext)
    #expect(k("\t", [.control, .shift]) == .tabPrev)
    #expect(k("]", [.command, .shift]) == .tabNext)
    #expect(k("[", [.command, .shift]) == .tabPrev)
    #expect(k("]", [.command, .option]) == .spaceNext)
    #expect(k("[", [.command, .option]) == .spacePrev)
    #expect(k("]", [.command]) == .agentNext)
    #expect(k("[", [.command]) == .agentPrev)
    #expect(k("1", [.command]) == .tabSelect(1))
    #expect(k("9", [.command]) == .tabSelect(9))
    #expect(k("2", [.control]) == .spaceSelect(2))
    // Not ours: the terminal's ⌘+ (German layout's key there), ⌘C, ⌘0, ⌘⇧1, ⌥1, tab alone.
    #expect(k("+", [.command]) == nil)
    #expect(k("c", [.command]) == nil)
    #expect(k("0", [.command]) == nil)
    #expect(k("1", [.command, .shift]) == nil)
    #expect(k("1", [.option]) == nil)
    #expect(k("\t", []) == nil)
}

@Test func selectCountsAsHerdrNumbersTabsAndSpaces() {
    let groups = [
        NavGroup(id: "sp1", tabs: [NavTab(id: "files", terminals: []), NavTab(id: "a", terminals: ["t1"]), NavTab(id: "b", terminals: ["t2"])]),
        NavGroup(id: "modonly", tabs: [NavTab(id: "x", terminals: [])]),
        NavGroup(id: "sp3", tabs: [NavTab(id: "c", terminals: ["t5"])]),
    ]
    let go = { (nav: Navigation, from: String) in Navigator.target(nav, from: from, groups: groups, agents: [], memory: NavMemory()) }
    #expect(go(.tabSelect(2), "t2") == "t1", "Herdr's tab 2, after a mod-only tab 1")
    #expect(go(.tabSelect(1), "t2") == nil, "a mod-only tab has no terminal to show")
    #expect(go(.spaceSelect(3), "t1") == "t5")
    #expect(go(.spaceSelect(2), "t1") == nil)
    #expect(go(.spaceSelect(1), "t5") == "t1", "a space lands on its first tab with a terminal")
    #expect(go(.spaceNext, "t1") == "t5", "next skips the empty space")
}

@Test func closingGoesBackToTheTabShownBefore() {
    var memory = NavMemory()
    for t in ["t1", "t5", "t9", "t3", "t2"] { memory.note(t, in: groups) }
    let live: Set = ["t1", "t5", "t3", "t2"]
    // Closing t2's tab (t2, t3 share it): back to t9? not live any more, so t5.
    #expect(memory.previous(excluding: ["t2", "t3"], isLive: live.contains) == "t5")
    memory.note("t5", in: groups)
    #expect(memory.history.suffix(2) == ["t2", "t5"], "revisiting moves it to the end, once")
    #expect(NavMemory().previous(excluding: [], isLive: { _ in true }) == nil)
}
