import AppKit
import HerdrCore
import SwiftUI

/// Herdr's switching keys for one window, handled before the terminal and the menus see
/// them: independent of SwiftUI focus (a disabled menu item would pass ⌘1 on to the
/// program) and never typed into the terminal. Matched as Herdr matches keys: by the
/// layout's character for the key (see NavigationKeys). The Go menu shows the same keys
/// and runs the same commands when clicked.
struct WindowKeys: NSViewRepresentable {
    let selection: String?
    let navigate: (Navigation) -> Void
    /// ⌘W: close the current tab (as Herdr's own ⌘W), not the window.
    let closeTab: () -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.navigate = navigate
        view.closeTab = closeTab
        view.selection = selection
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

    final class MonitorView: NSView {
        var navigate: ((Navigation) -> Void)?
        var closeTab: (() -> Void)?
        var selection: String? { didSet { publish() } }
        private var monitor: Any?
        /// Keys whose press we took: their release is ours too, so the terminal (by then
        /// another one) never gets a release without its press.
        private var swallowed: Set<UInt16> = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            publish()
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self else { return event }
                // A release belongs to its press, wherever focus went in between (⌘` to
                // another window): no window got the press, so none should get the release.
                if event.type == .keyUp {
                    return self.swallowed.remove(event.keyCode) != nil ? nil : event
                }
                guard let window = self.window, event.window === window, window.attachedSheet == nil else { return event }
                if Self.isCloseTab(event) {
                    self.swallowed.insert(event.keyCode)
                    self.closeTab?()
                    return nil
                }
                guard let nav = Self.navigation(for: event) else { return event }
                self.swallowed.insert(event.keyCode)
                self.navigate?(nav)
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            swallowed.removeAll()
            // A later window may get this number: it mustn't inherit what this one showed.
            if let published { DebugHarness.selections[published] = nil }
            published = nil
        }

        private var published: Int?

        /// For the test harness: what this window shows.
        private func publish() {
            guard let window else { return }
            if let published, published != window.windowNumber { DebugHarness.selections[published] = nil }
            published = window.windowNumber
            DebugHarness.selections[window.windowNumber] = selection
        }

        static func isCloseTab(_ event: NSEvent) -> Bool {
            event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.command]
                && event.characters(byApplyingModifiers: []) == "w"
        }

        static func navigation(for event: NSEvent) -> Navigation? {
            let f = event.modifierFlags
            var m: NavigationKeys.Modifiers = []
            if f.contains(.command) { m.insert(.command) }
            if f.contains(.control) { m.insert(.control) }
            if f.contains(.option) { m.insert(.option) }
            if f.contains(.shift) { m.insert(.shift) }
            let key = event.keyCode == 48 ? "\t" : (event.characters(byApplyingModifiers: []) ?? "")
            return NavigationKeys.navigation(key: key, modifiers: m)
        }
    }
}
