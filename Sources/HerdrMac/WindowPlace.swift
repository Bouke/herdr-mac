import AppKit
import SwiftUI

/// Puts the window back where it was when the app quit. SwiftUI's frame autosave keys the
/// place by window number and view type, and didn't reliably bring the window back after ⌘Q;
/// this keeps one place for the app. Only the first window goes back there; more windows
/// (⌥⌘N) open where macOS puts them, and the one moved last decides the next launch.
struct WindowPlace: NSViewRepresentable {
    static let key = "HerdrMac Window Frame"

    func makeNSView(context: Context) -> PlaceView { PlaceView() }
    func updateNSView(_ view: PlaceView, context: Context) {}

    final class PlaceView: NSView {
        private static var restored = false
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            DebugHarness.trace("place: moved to window \(window?.windowNumber ?? -1)")
            guard let window else { return }
            let saved = Self.restored ? nil : UserDefaults.standard.string(forKey: WindowPlace.key)
            Self.restored = true
            // After SwiftUI has placed the window; saving starts only then, so SwiftUI's
            // own placement never overwrites the place we're about to restore.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window === window else { return }
                DebugHarness.trace("place: restoring \(saved ?? "nothing")")
                // The plain frame, not NSWindow's descriptor: that one finds its screen by size,
                // and with two screens of the same size it puts the window on the wrong one.
                if let saved {
                    let frame = NSRectFromString(saved)
                    if frame.width > 0, NSScreen.screens.contains(where: { $0.visibleFrame.intersection(frame).width >= 100 }) {
                        window.setFrame(frame, display: true)
                    }
                }
                let save = {
                    MainActor.assumeIsolated {
                        guard !window.styleMask.contains(.fullScreen) else { return }
                        DebugHarness.trace("place: saving \(window.frame)")
                        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: WindowPlace.key)
                    }
                }
                let center = NotificationCenter.default
                for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification] {
                    self.observers.append(center.addObserver(forName: name, object: window, queue: .main) { _ in save() })
                }
                // ⌘Q: the windows don't close first.
                self.observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in save() })
            }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
