import Foundation
import Testing
@testable import HerdrCore

@Test func framesSurviveArbitraryChunking() {
    let frames = [
        Frame(channel: 0, kind: .data, payload: Data(#"{"id":1}"#.utf8)),
        Frame(channel: 7, kind: .close, payload: Data()),
        Frame(channel: 300, kind: .data, payload: Data(repeating: 0xAB, count: 70_000)),
    ]
    let wire = frames.map { $0.encoded() }.reduce(Data(), +)
    var decoder = FrameDecoder()
    var got: [Frame] = []
    var i = wire.startIndex
    while i < wire.endIndex {
        let j = min(i + 5, wire.endIndex)
        got += decoder.push(wire.subdata(in: i..<j))
        i = j
    }
    #expect(got == frames)
}

@Test func headerIsLittleEndianChannelKindLength() {
    let bytes = [UInt8](Frame(channel: 0x0102, kind: .credit, payload: Data([9, 9])).encoded())
    #expect(bytes == [0x02, 0x01, 0, 0, 1, 2, 0, 0, 0, 9, 9])
}

@Test func spacesComeFromTheDocumentTree() throws {
    let doc = try JSON.parse(Data(#"""
    {"spaces":[{"id":"sp1","name":"","folder":"/x/repo","tabs":[
      {"id":"tb1","name":"","root":{"type":"row","children":[
        {"type":"block","content":{"terminal":"t1"}},
        {"type":"column","children":[{"type":"block","content":{"terminal":"t2"}},{"type":"block","content":{"mod":"files"}}]}]}},
      {"id":"tb2","name":"fix","root":{"type":"block","content":{"terminal":"t3"}}}]}]}
    """#.utf8))
    let spaces = HerdrDocument.spaces(from: doc)
    #expect(spaces.count == 1)
    #expect(spaces[0].tabs.map(\.terminals) == [["t1", "t2"], ["t3"]])
    #expect(spaces[0].tabs.map(\.displayName) == ["1", "fix"])
}

@Test func eventsUpdateStatusAndIgnoreStaleSeq() {
    var events = TerminalEvents()
    events.reset(snapshot: ["seq": 5, "terminals": [["address": "t1", "state": "live", "status": ["app": "claude-code", "state": "working"]]]])
    let line = { (seq: Int, type: String, data: JSON) -> Data in
        let event: JSON = ["method": "event", "params": ["seq": .number(Double(seq)), "type": .string(type), "terminal": "t1", "data": data]]
        return event.data() + Data("\n".utf8)
    }
    _ = events.push(line(4, "status", ["status": ["app": "claude-code", "state": "blocked"]]))
    #expect(events.byAddress["t1"]?.agentState == .working)
    let pushed = events.push(line(6, "status", ["status": ["app": "claude-code", "state": "done"]]))
    #expect(pushed.terminals)
    #expect(events.byAddress["t1"]?.agentState == .done)
    _ = events.push(line(7, "removed", [:]))
    #expect(events.byAddress["t1"] == nil)
}

@Test func mostUrgentStateWins() {
    #expect([AgentState.idle, .working, .done].min() == .done)
    #expect([AgentState.working, .blocked].min() == .blocked)
}

@Test func shellQuotingSurvivesHostileWords() throws {
    let argv = ["/Users/me/odd dir/hc", "attach", "t7'; rm -rf ~; echo '", "$(whoami)", "a\"b`c`"]
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "printf '%s\\n' " + Shell.line(Array(argv.dropFirst()))]
    let out = Pipe()
    p.standardOutput = out
    try p.run()
    p.waitUntilExit()
    let lines = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").map(String.init)
    #expect(lines == Array(argv.dropFirst()))
    #expect(Shell.quote("it's") == #"'it'\''s'"#)
}

@Test func eventsMatchHerdrAppSemantics() {
    var events = TerminalEvents()
    events.reset(snapshot: ["seq": 1, "terminals": [["address": "t1", "state": "live", "title": "a"]]])
    let line = { (seq: Int, type: String, t: String, data: JSON) -> Data in
        let event: JSON = ["method": "event", "params": ["seq": .number(Double(seq)), "type": .string(type), "terminal": .string(t), "data": data]]
        return event.data() + Data("\n".utf8)
    }
    // A change for a terminal we don't know is ignored; created adds it whole.
    #expect(!events.push(line(2, "title", "t9", ["title": "x"])).terminals)
    #expect(events.push(line(3, "created", "t9", ["address": "t9", "state": "live"])).terminals)
    // labels with a record replace the terminal whole.
    _ = events.push(line(4, "labels", "t1", ["record": ["address": "t1", "state": "live", "title": "b", "labels": ["k": "v"]]]))
    #expect(events.byAddress["t1"]?.title == "b" && events.byAddress["t1"]?.label("k") == "v")
    // lost keeps it live without a pid or foreground; finished marks it finished.
    _ = events.push(line(5, "lost", "t1", ["reason": "x"]))
    #expect(events.byAddress["t1"]?.isLive == true && events.byAddress["t1"]?.raw["foreground"] == .null)
    _ = events.push(line(6, "finished", "t9", ["exit_code": 0]))
    #expect(events.byAddress["t9"]?.isLive == false)
    // A doc event asks for a reload; missed replaces everything.
    #expect(events.push(line(7, "doc", "", [:])).docs)
    let missed: JSON = ["method": "missed", "params": ["seq": 20, "terminals": [["address": "t5", "state": "live"]]]]
    let pushed = events.push(missed.data() + Data("\n".utf8))
    #expect(pushed.terminals && pushed.docs && Array(events.byAddress.keys) == ["t5"])
    // Lines split across chunks still apply.
    let split = line(21, "title", "t5", ["title": "joined"])
    _ = events.push(split.prefix(10))
    _ = events.push(split.dropFirst(10))
    #expect(events.byAddress["t5"]?.title == "joined")
}

/// Real shapes from herdr-core 0.1.22 (ids shortened): a labels event carries only `labels`.
@Test func aLabelsEventKeepsTheTerminalLive() throws {
    var events = TerminalEvents()
    let snapshot = try JSON.parse(Data(#"""
    {"seq":17466,"terminals":[{"address":"t7","argv":["/opt/homebrew/bin/fish","-l"],"cols":151,"created_ms":1700000000000,
     "cwd":"/x","die_with_parent":false,"exit_code":null,"finished_ms":null,"foreground":{"argv":["claude"],"cwd":"/x","name":"claude","pid":101},
     "identity":"ghostty","keep":true,"labels":{"herdr.seen":"7","herdr.space":"sp1","herdr.tab":"tb1"},"name":null,"notify":true,"parent":null,
     "pid":100,"reason":null,"reported":true,"rm":false,"rows":43,"screen":"exact","signal":null,"state":"live",
     "status":{"app":"claude-code","state":"working"},"status_ms":1,"template":null,"title":"t","turn":1}]}
    """#.utf8))
    events.reset(snapshot: snapshot)
    #expect(events.byAddress["t7"]?.isLive == true)
    let line = #"{"jsonrpc":"2.0","method":"event","params":{"data":{"labels":{"herdr-mac.probe":"1","herdr.seen":"7","herdr.space":"sp1","herdr.tab":"tb1"}},"seq":17467,"terminal":"t7","type":"labels"}}"#
    _ = events.push(Data((line + "\n").utf8))
    #expect(events.byAddress["t7"]?.isLive == true)
    #expect(events.byAddress["t7"]?.label("herdr-mac.probe") == "1")
}

@Test func aTabStartedHereShowsBeforeHerdrWritesIt() {
    let doc = [Space(id: "sp1", name: "", folder: "/r", machine: nil, tabs: [SpaceTab(id: "tb1", name: "", index: 0, terminals: ["t1"])])]
    let mine = PendingTab(space: "sp1", folder: "/r", tab: SpaceTab(id: "tbNew", name: "", index: 0, terminals: ["t9"]))
    let fresh = PendingTab(space: "spNew", folder: "/s", tab: SpaceTab(id: "tbX", name: "", index: 0, terminals: ["t8"]))
    let merged = HerdrDocument.merge(doc, pending: [mine, fresh])
    #expect(merged[0].tabs.map(\.terminals) == [["t1"], ["t9"]])
    #expect(merged[0].tabs[1].displayName == "2", "numbered after the space's tabs")
    #expect(merged.map(\.id) == ["sp1", "spNew"], "a new space goes last")
    // Once Herdr's document has the tab, the pending one adds nothing.
    let written = [Space(id: "sp1", name: "", folder: "/r", machine: nil, tabs: doc[0].tabs + [SpaceTab(id: "tbNew", name: "", index: 1, terminals: ["t9"])])]
    #expect(HerdrDocument.merge(written, pending: [mine]) == written)
}

@Test func aProvisionalTerminalGivesWayToTheRealOne() {
    var events = TerminalEvents()
    events.reset(snapshot: ["seq": 1, "terminals": []])
    events.provisional(["address": "t9", "state": "live", "cwd": "/r"])
    #expect(events.byAddress["t9"]?.isLive == true)
    let created: JSON = ["method": "event", "params": ["seq": 2, "type": "created", "terminal": "t9",
                                                        "data": ["address": "t9", "state": "live", "cwd": "/r", "title": "real"]]]
    _ = events.push(created.data() + Data("\n".utf8))
    #expect(events.byAddress["t9"]?.title == "real")
    // A created event that came first is never overwritten by the provisional record.
    events.provisional(["address": "t9", "state": "live"])
    #expect(events.byAddress["t9"]?.title == "real")
}

@Test func onlyShellsAtTheirPromptAreSafeToClose() {
    let t = { (raw: JSON) in CoreTerminal(raw) }
    #expect(t(["address": "t1", "foreground": ["name": "zsh"]]).isShell)
    #expect(t(["address": "t1", "foreground": ["name": "-fish"]]).isShell)
    #expect(t(["address": "t1", "argv": ["/opt/homebrew/bin/fish", "-l"]]).isShell)
    #expect(!t(["address": "t1", "foreground": ["name": "vim"]]).isShell)
    #expect(!t(["address": "t1", "foreground": ["name": "zsh"], "status": ["app": "claude-code", "state": "idle"]]).isShell,
            "an agent is never just a shell")
}

@Test func doneIsOnlyDoneUntilSomeoneLooked() {
    let t = { (state: String, turn: Int, seen: String?) -> CoreTerminal in
        var labels: [String: JSON] = [:]
        if let seen { labels["herdr.seen"] = .string(seen) }
        return CoreTerminal(["address": "t1", "status": ["app": "claude-code", "state": .string(state)],
                             "turn": .number(Double(turn)), "labels": .object(labels)])
    }
    #expect(t("done", 47, "47").shownState == .idle, "seen: idle again, as in Herdr")
    #expect(t("done", 48, "47").shownState == .done, "a newer turn finished unseen")
    #expect(t("done", 48, nil).shownState == .done)
    #expect(t("done", 48, "47").needsSeen && !t("done", 47, "47").needsSeen)
    #expect(t("working", 48, "47").shownState == .working)
    #expect(t("blocked", 48, "48").shownState == .blocked, "blocked stays until answered")
}

@Test func aResizeIsKeptButNotAnnounced() {
    var events = TerminalEvents()
    events.reset(snapshot: ["seq": 1, "terminals": [["address": "t1", "state": "live", "cols": 80, "rows": 24]]])
    let line: JSON = ["method": "event", "params": ["seq": 2, "type": "size", "terminal": "t1", "data": ["cols": 120, "rows": 40]]]
    #expect(!events.push(line.data() + Data("\n".utf8)).terminals, "a window being resized must not re-render everything")
    #expect(events.byAddress["t1"]?.raw["cols"].int == 120)
}

@Test func parsingKeepsBoolsNumbersAndNesting() throws {
    let j = try JSON.parse(Data(#"{"a": true, "b": 1, "c": 1.5, "d": [false, null, "x"], "e": {"f": 0}}"#.utf8))
    #expect(j["a"] == .bool(true) && j["b"] == .number(1) && j["c"] == .number(1.5))
    #expect(j["d"] == .array([.bool(false), .null, .string("x")]) && j["e"]["f"] == .number(0))
}
