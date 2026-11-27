import AppKit
import SwiftUI

/// The focused window's tab and space actions, for the File menu. Equal by window, as
/// `Navigate` (a closure can't be compared; SwiftUI would rebuild the menus endlessly).
struct WindowActions: Equatable {
    let window: UUID
    let newTab: @MainActor () -> Void
    let newSpace: @MainActor () -> Void
    let closeTab: @MainActor () -> Void
    static func == (a: WindowActions, b: WindowActions) -> Bool { a.window == b.window }
}

extension FocusedValues {
    @Entry var windowActions: WindowActions?
}

/// File menu: New Tab ⌘T, New Space… ⌘N and Close Tab ⌘W, as in Herdr's keys.json.
/// (⌘W reaches WindowKeys first, which closes the tab the same way; the item shows the key.)
struct FileCommands: Commands {
    @FocusedValue(\.windowActions) private var actions

    var body: some Commands {
        CommandGroup(before: .newItem) {
            Button("New Tab") { actions?.newTab() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(actions == nil)
            Button("New Space…") { actions?.newSpace() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(actions == nil)
            Button("Close Tab") { actions?.closeTab() }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(actions == nil)
            Divider()
        }
    }

    /// The system's own File items on ⌘N and ⌘W (New Window, Close) move to ⌥⌘N and ⌘⇧W,
    /// as in Safari: the plain keys are Herdr's (new space, close tab).
    /// SwiftUI drops their keys when ours take ⌘N/⌘W, so they're found by action and title.
    @MainActor static func moveSystemShortcuts() {
        let file = NSApp.mainMenu?.items.dropFirst().first?.submenu?.items ?? []
        for item in file {
            if item.action == #selector(NSWindow.performClose(_:)) {
                item.keyEquivalent = "w"
                item.keyEquivalentModifierMask = [.command, .shift]
            } else if item.title.hasPrefix("New"), item.title.hasSuffix("Window") {
                item.keyEquivalent = "n"
                item.keyEquivalentModifierMask = [.command, .option]
            }
        }
    }
}
