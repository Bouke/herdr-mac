import AppKit
import HerdrCore
import SwiftUI
import TerminalKit

@main
struct HerdrMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = HerdrStore()
    @State private var look = Look()
    @State private var mods = ModHost()
    @State private var places = ModPlaces()

    init() {
        // Started from inside a core terminal (`open` from a shell there), the app inherits
        // that terminal's identity. hc would then treat every attach, run and call as coming
        // from that terminal: refuse to attach to it ("attached to itself") and make new
        // shells its children, ending with it. The app is never inside a terminal.
        for name in ["HC_TERMINAL_ID", "HC_TERMINAL_SOCKET", "HC_SCOPE"] { unsetenv(name) }
        // AppKit's window restoration sometimes brings the app back with no window at all
        // (after a kill). The terminals live in herdr-core, so there's nothing to restore.
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
    }

    var body: some Scene {
        // One fixed view type: SwiftUI remembers the window's place (frame autosave) under a
        // name made from this type, so modifiers stay inside MainWindow, or every change to
        // them would start a new name and forget where the window was.
        WindowGroup("Herdr") {
            MainWindow(store: store, look: look, mods: mods, places: places)
        }
        .defaultSize(width: 1280, height: 800)
        .windowToolbarStyle(.unified)
        // A restored "no windows" state would leave the app running without a window.
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updater.shared.check(manual: true) }
            }
            FileCommands()
            NavigationCommands()
        }
    }
}

struct MainWindow: View {
    let store: HerdrStore
    let look: Look
    let mods: ModHost
    let places: ModPlaces

    var body: some View {
        ContentView()
            .environment(store)
            .environment(look)
            .environment(mods)
            .environment(places)
            .task { look.start(); store.start() }
            .frame(minWidth: 640, minHeight: 360)
            .background(WindowPlace())
            // A see-through window: the desktop, blurred, behind the glass sidebar
            // and the (translucent) terminal.
            .containerBackground(.ultraThinMaterial, for: .window)
            // Light or dark as the system is, unless Herdr's settings.json forces one.
            .preferredColorScheme(look.forcedScheme)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A bare SwiftPM executable starts as a background process.
        NSApp.setActivationPolicy(.regular)
        // No AppKit window tabs: they'd add their own ⌃⇥ items; tabs here are Herdr's.
        NSWindow.allowsAutomaticWindowTabbing = false
        // ⌘N and ⌘W are Herdr's here (new space, close tab): the system's New Window and
        // Close move to ⌥⌘N and ⌘⇧W, as in Safari.
        DispatchQueue.main.async { MainActor.assumeIsolated { FileCommands.moveSystemShortcuts() } }
        DebugHarness.install()
        MainActor.assumeIsolated { Updater.shared.start() }
        _ = MainActor.assumeIsolated { GhosttyRuntime.shared }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
