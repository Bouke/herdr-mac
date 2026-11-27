import AppKit
import HerdrCore
import SwiftUI
import TerminalKit

/// Light/dark and fonts, from the system appearance and the person's Herdr settings.json
/// (the file herdr-app reads), applied live to the window and every terminal.
@MainActor @Observable
final class Look {
    private(set) var settings = HerdrSettings.load()
    private(set) var keys = HerdrKeys.load()
    /// Set in start(): NSApp doesn't exist yet when the App struct is made.
    private(set) var systemDark = true

    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var keysWatcher: FileWatcher?

    var dark: Bool { settings.forcedDark ?? systemDark }

    /// Herdr's `appearance` forces a scheme; without it the window follows the system.
    var forcedScheme: ColorScheme? { settings.forcedDark.map { $0 ? .dark : .light } }

    /// Herdr's `ui_font`, when the person set one; otherwise the system font (native look).
    var uiFont: Font? { settings.raw["ui_font"].string.map { .custom($0, size: NSFont.systemFontSize) } }

    func start() {
        guard watcher == nil else { return }
        systemDark = Look.isDark(NSApp.effectiveAppearance)
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { app, _ in
            MainActor.assumeIsolated {
                self.systemDark = Look.isDark(app.effectiveAppearance)
                self.push()
            }
        }
        watcher = FileWatcher(HerdrSettings.defaultURL) { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        keysWatcher = FileWatcher(HerdrKeys.defaultURL) { [weak self] in
            MainActor.assumeIsolated { self?.reloadKeys() }
        }
        reload() // anything changed between loading the files and watching them
        reloadKeys()
        push()
    }

    private func reload() {
        // A half-written or broken file keeps the last good settings, as herdr-app does.
        guard let new = HerdrSettings.read(), new != settings else { return }
        settings = new
        push()
    }

    private func reloadKeys() {
        guard let new = HerdrKeys.read(), new != keys else { return }
        keys = new
        push()
    }

    private func push() { GhosttyRuntime.shared.apply(settings: settings, keys: keys, dark: dark) }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
