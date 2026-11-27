import AppKit
import SwiftUI

/// A herdr-core terminal, live in libghostty. The surface runs `herdr-mac-attach` (shipped
/// next to the app's executable), which shares the terminal politely with other windows:
/// it takes the terminal's size only while this surface has keyboard focus. Removing the
/// view ends only the attach; the terminal keeps running in herdr-core.
public struct TerminalView: NSViewRepresentable {
    let address: String
    let hcPath: String
    let observe: Bool
    /// The one shown: started with the size, given keyboard focus. Hidden copies (kept for
    /// quick switching) never take the size and don't draw.
    let active: Bool
    let onDetach: () -> Void

    /// `observe`: watch only (`hc attach --observe`): never types into or resizes the terminal.
    public init(address: String, hcPath: String, observe: Bool = false, active: Bool = true, onDetach: @escaping () -> Void = {}) {
        self.address = address
        self.hcPath = hcPath
        self.observe = observe
        self.active = active
        self.onDetach = onDetach
    }

    static var relay: String? {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/herdr-mac-attach").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    public func makeNSView(context: Context) -> GhosttySurfaceView {
        let command: [String]
        if !observe, let relay = Self.relay {
            command = [relay, "--hc", hcPath] + (active ? ["--active"] : []) + [address]
        } else {
            command = [hcPath, "attach", "--history", "5000"] + (observe ? ["--observe"] : []) + [address]
        }
        let view = GhosttySurfaceView(command: command)
        view.onClose = onDetach
        view.setVisible(active)
        return view
    }

    public func updateNSView(_ view: GhosttySurfaceView, context: Context) {
        view.onClose = onDetach
        view.setVisible(active)
        // Shown again: it gets the keyboard (and so, through the relay, the size).
        if active, view.window?.firstResponder !== view {
            DispatchQueue.main.async { if view.window?.firstResponder !== view { view.window?.makeFirstResponder(view) } }
        }
    }

    public static func dismantleNSView(_ view: GhosttySurfaceView, coordinator: ()) {
        view.onClose = nil
        view.close()
    }
}
