import AppKit
import GhosttyKit
import HerdrCore

/// The one libghostty app of this process: its config and the runtime callbacks
/// (wakeups, clipboard, closing surfaces, actions). Main thread only.
@MainActor
public final class GhosttyRuntime {
    public static let shared = GhosttyRuntime()

    public private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?
    public private(set) var error: String?

    /// Our defaults, loaded before the person's own Ghostty config so theirs wins.
    /// Key bindings are cleared: the app's menus own ⌘-keys (⌘Q, ⌘W...), the terminal
    /// keeps only what belongs to it.
    static let defaults = """
    window-padding-x = 10
    window-padding-y = 8
    window-padding-balance = true
    background-opacity = 0.72
    confirm-close-surface = false
    quit-after-last-window-closed = false
    shell-integration = none
    keybind = clear
    keybind = super+c=copy_to_clipboard
    keybind = super+v=paste_from_clipboard
    keybind = super+a=select_all
    keybind = super+equal=increase_font_size:1
    keybind = super+plus=increase_font_size:1
    keybind = super+minus=decrease_font_size:1
    keybind = super+zero=reset_font_size
    keybind = shift+page_up=scroll_page_up
    keybind = shift+page_down=scroll_page_down
    keybind = super+home=scroll_to_top
    keybind = super+end=scroll_to_bottom
    keybind = super+up=jump_to_prompt:-1
    keybind = super+down=jump_to_prompt:1
    """

    /// What the current config was made from; `apply` rebuilds only when these change.
    public private(set) var settings = HerdrSettings()
    public private(set) var keys = HerdrKeys()
    public private(set) var dark = true

    private static let support: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HerdrMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Our defaults, then the person's own Ghostty config, then their Herdr settings
    /// (fonts, theme for this appearance...), so herdr-app's settings.json wins, as in Herdr.
    private func makeConfig() -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }
        let defaults = Self.support.appendingPathComponent("ghostty-defaults.conf")
        try? Self.defaults.write(to: defaults, atomically: true, encoding: .utf8)
        ghostty_config_load_file(config, defaults.path)
        ghostty_config_load_default_files(config)
        ghostty_config_load_recursive_files(config)
        let herdr = Self.support.appendingPathComponent("ghostty-herdr-settings.conf")
        let themes = HerdrSettings.defaultURL.deletingLastPathComponent().appendingPathComponent("themes")
        // Herdr's keys.json `send:` bindings (⌥⌫ deletes a word...) after our `keybind = clear`.
        let text = ([settings.ghosttyConfig(dark: dark, themesDir: themes)] + keys.ghosttyKeybinds()).joined(separator: "\n")
        try? text.write(to: herdr, atomically: true, encoding: .utf8)
        ghostty_config_load_file(config, herdr.path)
        ghostty_config_finalize(config)
        return config
    }

    /// Applies new Herdr settings and/or appearance to every terminal, live.
    public func apply(settings: HerdrSettings, keys: HerdrKeys, dark: Bool) {
        guard settings != self.settings || keys != self.keys || dark != self.dark else { return }
        self.settings = settings
        self.keys = keys
        self.dark = dark
        guard let app, let config = makeConfig() else { return }
        ghostty_app_update_config(app, config)
        ghostty_app_set_color_scheme(app, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
        if let old = self.config { ghostty_config_free(old) }
        self.config = config
    }

    private init() {
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            error = "ghostty_init failed"
            return
        }
        settings = HerdrSettings.load()
        keys = HerdrKeys.load()
        dark = settings.forcedDark ?? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        guard let config = makeConfig() else { error = "ghostty_config_new failed"; return }
        self.config = config

        var runtime = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in DispatchQueue.main.async { MainActor.assumeIsolated { GhosttyRuntime.shared.tick() } } },
            action_cb: { app, target, action in GhosttyRuntime.handle(target: target, action: action) },
            read_clipboard_cb: { userdata, location, state, mimes, count, list in
                GhosttyRuntime.readClipboard(userdata, location: location, state: state, mimes: mimes, count: count, list: list)
            },
            confirm_read_clipboard_cb: { userdata, confirm, state, request in
                GhosttyRuntime.confirmReadClipboard(userdata, confirm: confirm, state: state, request: request)
            },
            write_clipboard_cb: { _, location, content, count, _ in
                GhosttyRuntime.writeClipboard(location: location, content: content, count: count)
            },
            close_surface_cb: { userdata, _ in
                guard let view = GhosttyRuntime.view(userdata) else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { view.surfaceDidClose() } }
            }
        )
        guard let app = ghostty_app_new(&runtime, config) else { error = "ghostty_app_new failed"; return }
        self.app = app
        ghostty_app_set_focus(app, NSApp.isActive)
        ghostty_app_set_color_scheme(app, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if let app = GhosttyRuntime.shared.app { ghostty_app_set_focus(app, true) } }
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if let app = GhosttyRuntime.shared.app { ghostty_app_set_focus(app, false) } }
        }
    }

    func tick() { if let app { ghostty_app_tick(app) } }

    /// The terminal's background color from the Ghostty config, so chrome can match it.
    public var backgroundColor: NSColor {
        var color = ghostty_config_color_s()
        guard let config, ghostty_config_get(config, &color, "background", UInt("background".utf8.count)) else {
            return .textBackgroundColor
        }
        return NSColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1)
    }

    // MARK: Callbacks

    nonisolated static func view(_ userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceView? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    nonisolated static func handle(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            guard target.tag == GHOSTTY_TARGET_SURFACE, let view = view(ghostty_surface_userdata(target.target.surface)) else { return false }
            let shape = action.action.mouse_shape
            DispatchQueue.main.async { MainActor.assumeIsolated { view.setCursor(shape) } }
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            let u = action.action.open_url
            guard let ptr = u.url else { return false }
            let text = String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(u.len)), as: UTF8.self)
            if let url = URL(string: text), url.scheme != nil { NSWorkspace.shared.open(url) }
            else { NSWorkspace.shared.open(URL(fileURLWithPath: text)) }
            return true
        case GHOSTTY_ACTION_RING_BELL:
            NSSound.beep()
            return true
        default:
            return false
        }
    }

    nonisolated static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?, location: ghostty_clipboard_e, state: UnsafeMutableRawPointer?,
        mimes: UnsafePointer<UnsafePointer<CChar>?>?, count: Int, list: Bool
    ) -> ghostty_clipboard_read_result_e {
        guard location == GHOSTTY_CLIPBOARD_STANDARD, let surface = view(userdata)?.surface else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
        let wanted = (0..<count).compactMap { mimes?[$0].map { String(cString: $0) } }
        guard let text = NSPasteboard.general.string(forType: .string),
              let mime = wanted.first(where: { $0.hasPrefix("text/plain") }) ?? (wanted.isEmpty ? "text/plain" : nil)
        else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        complete(surface, mime: mime, text: text, confirmed: false, state: state)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    /// Ghostty asks before an unsafe paste or a program reading the clipboard (OSC 52).
    /// The prototype allows the person's own pastes and denies programs' reads.
    nonisolated static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?, confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
        state: UnsafeMutableRawPointer?, request: ghostty_clipboard_request_e
    ) {
        guard let surface = view(userdata)?.surface else { return }
        guard request == GHOSTTY_CLIPBOARD_REQUEST_PASTE, let c = confirm?.pointee, c.contents_len > 0, let first = c.contents?[0],
              let mime = first.mime, let data = first.data
        else { ghostty_surface_deny_clipboard_request(surface, state); return }
        let text = String(decoding: UnsafeRawBufferPointer(start: data, count: first.len), as: UTF8.self)
        complete(surface, mime: String(cString: mime), text: text, confirmed: true, state: state)
    }

    nonisolated static func complete(_ surface: ghostty_surface_t, mime: String, text: String, confirmed: Bool, state: UnsafeMutableRawPointer?) {
        mime.withCString { cMime in
            text.withCString { cText in
                var content = ghostty_clipboard_content_s(mime: cMime, data: cText, len: strlen(cText))
                withUnsafePointer(to: &content) { contents in
                    var done = ghostty_clipboard_complete_s(contents: contents, contents_len: 1, available: nil, available_len: 0,
                                                            confirmed: confirmed, remember: false)
                    ghostty_surface_complete_clipboard_request(surface, &done, state)
                }
            }
        }
    }

    nonisolated static func writeClipboard(location: ghostty_clipboard_e, content: UnsafePointer<ghostty_clipboard_content_s>?, count: Int) {
        guard location == GHOSTTY_CLIPBOARD_STANDARD, let content else { return }
        for i in 0..<count {
            let item = content[i]
            guard let mime = item.mime, String(cString: mime).hasPrefix("text/plain"), let data = item.data else { continue }
            let text = String(decoding: UnsafeRawBufferPointer(start: data, count: item.len), as: UTF8.self)
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return
        }
    }
}
