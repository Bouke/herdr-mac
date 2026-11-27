import HerdrCore
import SwiftUI

/// The focused window's switcher, for the Go menu. Equal by window, not by closure: a
/// closure can't be compared, so SwiftUI would treat every update as a change and rebuild
/// the menus in an endless loop.
struct Navigate: Equatable {
    let window: UUID
    let run: @MainActor (Navigation) -> Void
    static func == (a: Navigate, b: Navigate) -> Bool { a.window == b.window }
}

extension FocusedValues {
    @Entry var navigate: Navigate?
}

/// Herdr's switching keys (see herdr-app's keys.json), as a native Go menu.
struct NavigationCommands: Commands {
    @FocusedValue(\.navigate) private var navigate

    var body: some Commands {
        CommandMenu("Go") {
            Section {
                item("Next Tab", .tabNext, KeyEquivalent("]"), [.command, .shift])
                item("Previous Tab", .tabPrev, KeyEquivalent("["), [.command, .shift])
                item("Next Tab", .tabNext, .tab, .control)
                item("Previous Tab", .tabPrev, .tab, [.control, .shift])
            }
            Section {
                item("Next Space", .spaceNext, KeyEquivalent("]"), [.command, .option])
                item("Previous Space", .spacePrev, KeyEquivalent("["), [.command, .option])
            }
            Section {
                item("Next Agent", .agentNext, KeyEquivalent("]"), .command)
                item("Previous Agent", .agentPrev, KeyEquivalent("["), .command)
            }
            Menu("Tab") {
                ForEach(1...9, id: \.self) { n in
                    item("Tab \(n)", .tabSelect(n), KeyEquivalent(Character("\(n)")), .command)
                }
            }
            Menu("Space") {
                ForEach(1...9, id: \.self) { n in
                    item("Space \(n)", .spaceSelect(n), KeyEquivalent(Character("\(n)")), .control)
                }
            }
        }
    }

    private func item(_ title: String, _ nav: Navigation, _ key: KeyEquivalent, _ modifiers: EventModifiers) -> some View {
        Button(title) { navigate?.run(nav) }
            .keyboardShortcut(key, modifiers: modifiers)
            .disabled(navigate == nil)
    }
}
