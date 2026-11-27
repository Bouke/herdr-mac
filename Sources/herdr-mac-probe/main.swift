import Foundation
import HerdrCore

// Prints what the app would show: the core, Herdr's spaces and tabs, loose terminals,
// then follows live changes for a few seconds. `herdr-mac-probe [seconds]`.
let seconds = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 3

@MainActor func run() async {
    let store = HerdrStore()
    store.start()
    for _ in 0..<50 where store.spaces.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
    print("connection:", store.connection)
    for space in store.spaces {
        print("■ \(store.displayName(space))  [\(store.state(of: space.tabs.flatMap(\.terminals))?.rawValue ?? "-")]")
        for tab in space.tabs {
            let names = tab.terminals.map { a in "\(a) \(store.terminals[a]?.displayName ?? "?") (\(store.terminals[a]?.agentState?.rawValue ?? "-"))" }
            print("   tab \(tab.displayName): \(names.joined(separator: ", "))")
        }
    }
    print("loose:", store.looseTerminals.map { "\($0.address) \($0.displayName)" })
    var last = store.terminals
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        try? await Task.sleep(for: .milliseconds(200))
        for (a, t) in store.terminals where last[a] != t {
            print("changed: \(a) state=\(t.agentState?.rawValue ?? "-") title=\(t.title ?? "-")")
        }
        last = store.terminals
    }
}

await run()
