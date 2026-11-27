import AppKit
import HerdrCore
import TerminalKit

#if DEBUG
/// Test hooks for checking the real UI without a person at the keyboard.
///
/// - `kill -USR1 <pid>` writes the window to `$TMPDIR/herdr-mac-shot.png` (Metal included;
///   an app may always capture its own windows, so no Screen Recording permission).
/// - `kill -USR2 <pid>` runs `$TMPDIR/herdr-mac-keys.txt` and logs to
///   `$TMPDIR/herdr-mac-harness.log`. Key events go through `NSApp.sendEvent`, like real
///   keypresses (menus, performKeyEquivalent, keyDown), but stay inside this process:
///   they can never reach another app. Refused unless HERDR_MAC_ONLY_TYPE_IN names the test
///   terminals; key/text/pke stop unless one of those is selected. Script lines:
///     key ctrl+tab | key cmd+shift+] | key cmd+1     press a key combination
///     text echo hi                                    type text (letters, digits, space, - .)
///     require t56                                     stop unless this terminal is selected
///     pke cmd+1                                       which handler would take it (dry run)
///     nav tabNext | nav tab:2 | nav space:1           run a switching command as the Go menu does
///     menu                                            log the Go menu's items
///     activate                                        bring the app forward (takes focus!)
///     wait 300 | log label | shot name | where (the window's frame)
enum DebugHarness {
    /// What each window shows, by window number (WindowKeys publishes it).
    @MainActor static var selections: [Int: String] = [:]
    @MainActor static var selection: String? { window.flatMap { selections[$0.windowNumber] } }
    /// Lines from inside the app (the key monitor...), shown by the `trace` script line.
    @MainActor static var traces: [String] = []
    @MainActor static func trace(_ line: String) { traces.append(line); if traces.count > 100 { traces.removeFirst() } }
    /// The window's switcher, as the Go menu calls it.
    @MainActor static var navigate: ((Navigation) -> Void)?
    private nonisolated(unsafe) static var sources: [DispatchSourceSignal] = []

    static func install() {
        for (sig, action) in [(SIGUSR1, { MainActor.assumeIsolated { _ = capture("shot") } }), (SIGUSR2, { MainActor.assumeIsolated { runScript() } })] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler(handler: action)
            s.resume()
            sources.append(s)
        }
    }

    private static let tmp = FileManager.default.temporaryDirectory

    @MainActor private static var window: NSWindow? {
        NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && $0.frame.height > 100 }
    }

    // MARK: Snapshot

    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    @MainActor @discardableResult static func capture(_ name: String) -> String? {
        guard let window, let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        // CGWindowListCreateImage is obsoleted in the SDK but still present; own windows only.
        let create = unsafeBitCast(sym, to: CreateImage.self)
        guard let image = create(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0 | 1 << 3)?.takeRetainedValue() else { return nil }
        let url = tmp.appendingPathComponent(name == "shot" ? "herdr-mac-shot.png" : "herdr-mac-\(name).png")
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        return url.path
    }

    // MARK: Key script

    @MainActor private static var log: [String] = []

    /// Terminals a script may type into (`HERDR_MAC_ONLY_TYPE_IN`); every other terminal is
    /// attached watch-only then. Without it, scripts are refused.
    static let allowed: Set<String>? = ProcessInfo.processInfo.environment["HERDR_MAC_ONLY_TYPE_IN"]
        .map { Set($0.split(separator: ",").map(String.init)) }

    @MainActor static func runScript() {
        guard allowed != nil else {
            log = []
            finish("refused: set HERDR_MAC_ONLY_TYPE_IN to the test terminals first")
            return
        }
        let script = (try? String(contentsOf: tmp.appendingPathComponent("herdr-mac-keys.txt"), encoding: .utf8)) ?? ""
        log = []
        if NSApp.keyWindow == nil { log.append("note: no key window (app in the background or screen locked); add `activate` to take focus") }
        run(script.split(separator: "\n").map(String.init), at: 0)
    }

    @MainActor private static func run(_ lines: [String], at i: Int) {
        guard i < lines.count else { finish("done"); return }
        let line = lines[i].trimmingCharacters(in: .whitespaces)
        let (cmd, arg) = line.firstIndex(of: " ").map { (String(line[..<$0]), String(line[line.index(after: $0)...])) } ?? (line, "")
        var delay = 0.25
        if ["key", "text", "pke"].contains(cmd), !(allowed?.contains(selection ?? "") ?? false) {
            finish("ABORT: \(cmd) with \(selection ?? "nothing") selected, not a test terminal")
            return
        }
        switch cmd {
        case "key":
            guard let (code, chars, flags) = combo(arg) else { finish("bad key: \(arg)"); return }
            press(code, chars, flags)
        case "text":
            guard arg.allSatisfy({ keyFor($0) != nil }) else { finish("bad text: \(arg)"); return }
            for c in arg { let (code, shift) = keyFor(c)!; press(code, String(c), shift ? .shift : []) }
        case "require":
            guard selection == arg else { finish("ABORT: selection is \(selection ?? "nil"), not \(arg)"); return }
            delay = 0
        case "activate":
            // Takes focus from whatever the person is doing: only when the script asks.
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            delay = 0.8
        case "wait": delay = (Double(arg) ?? 300) / 1000
        case "log": log.append("\(arg): selection=\(selection ?? "nil") key=\(NSApp.keyWindow != nil) responder=\(type(of: window?.firstResponder as Any))"); delay = 0
        case "nav":
            let nav: Navigation? = switch arg {
            case "tabNext": .tabNext
            case "tabPrev": .tabPrev
            case "spaceNext": .spaceNext
            case "spacePrev": .spacePrev
            case "agentNext": .agentNext
            case "agentPrev": .agentPrev
            default:
                if arg.hasPrefix("tab:"), let n = Int(arg.dropFirst(4)) { .tabSelect(n) }
                else if arg.hasPrefix("space:"), let n = Int(arg.dropFirst(6)) { .spaceSelect(n) }
                else { nil }
            }
            guard let nav, let navigate else { finish("bad nav: \(arg)"); return }
            navigate(nav)
        case "pke":
            // A pure check: which handler would take this key? Nothing is performed.
            guard let (code, chars, flags) = combo(arg), let window,
                  let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { finish("bad key: \(arg)"); return }
            let nav = WindowKeys.MonitorView.navigation(for: e).map { "\($0)" } ?? "-"
            let binding = (window.firstResponder as? GhosttySurfaceView)?.isBinding(e) ?? false
            log.append("pke \(arg): switch=\(nav) terminal-binding=\(binding)")
            delay = 0
        case "menu": log.append("menu: \(goMenu())"); delay = 0
        case "quit": NSApp.terminate(nil); delay = 0
        case "where": log.append("where: \(window.map { "\($0.frame)" } ?? "no window")"); delay = 0
        case "frame":
            // frame x y w h: move the window as a person would (autosave sees it).
            let v = arg.split(separator: " ").compactMap { Double($0) }
            guard v.count == 4, let window else { finish("bad frame: \(arg)"); return }
            window.setFrame(NSRect(x: v[0], y: v[1], width: v[2], height: v[3]), display: true)
            log.append("frame set: \(window.frame) autosave=\(window.frameAutosaveName)")
            delay = 0.3
        case "drag":
            // drag <seconds>: widen and narrow the window every frame, as a person dragging its edge.
            guard let window else { finish("no window"); return }
            let start = window.frame, seconds = Double(arg) ?? 4, began = Date()
            Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { timer in
                MainActor.assumeIsolated {
                    let t = Date().timeIntervalSince(began)
                    guard t < seconds else { window.setFrame(start, display: true); timer.invalidate(); return }
                    var f = start
                    f.size.width = start.width - 300 + 300 * abs(sin(t * 1.5))
                    window.setFrame(f, display: true)
                }
            }
            delay = seconds + 0.3
        case "trace":
            log.append("trace: " + (traces.isEmpty ? "(nothing)" : traces.joined(separator: " | ")))
            traces = []
            delay = 0
        case "post":
            // Into the app's event queue, the way real keys arrive (run loop, then sendEvent).
            guard let (code, chars, flags) = combo(arg), let window else { finish("bad key: \(arg)"); return }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: chars,
                                            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
        case "updatemanual":
            Updater.shared.check(manual: true)
            delay = 3
        case "updatemessage":
            log.append("message: \(Updater.shared.message ?? "none") | sheet: \(window?.attachedSheet != nil) | windows: \(NSApp.windows.filter { $0.isVisible }.map { String(describing: type(of: $0)) }.joined(separator: ","))")
            delay = 0
        case "updatecheck":
            Updater.shared.check(manual: false)
            delay = 2
        case "updatelog":
            log.append("update: current \(Updater.shared.currentBuild), available \(Updater.shared.available.map { "\($0.version) (\($0.build))" } ?? "none")")
            delay = 0
        case "updateinstall":
            Updater.shared.install()
            delay = 0
        case "filemenu":
            // The File menu as AppKit has it: title [modifiers+key].
            let file = NSApp.mainMenu?.items.dropFirst().first?.submenu?.items ?? []
            log.append("file: " + file.filter { !$0.isSeparatorItem }.map { i in
                let m = i.keyEquivalentModifierMask
                let mods = (m.contains(.command) ? "⌘" : "") + (m.contains(.option) ? "⌥" : "") + (m.contains(.shift) || i.keyEquivalent != i.keyEquivalent.lowercased() ? "⇧" : "")
                return "\(i.title)[\(i.keyEquivalent.isEmpty ? "" : mods + i.keyEquivalent.lowercased())]\(i.isEnabled ? "" : " (off)")"
            }.joined(separator: ", "))
            delay = 0
        case "wmenu":
            // Every menu item on a W key: which one owns ⌘W now.
            let items = NSApp.mainMenu?.items.flatMap { $0.submenu?.items ?? [] }.filter { $0.keyEquivalent.lowercased() == "w" } ?? []
            log.append("w items: " + items.map { "\($0.title)[\($0.keyEquivalent)]" }.joined(separator: ", "))
            delay = 0
        case "dialog": log.append("dialog: \(window?.attachedSheet != nil || NSApp.windows.contains { $0.isVisible && $0.className.contains("Alert") })"); delay = 0
        case "shot": log.append("shot \(arg): \(capture(arg) ?? "failed")"); delay = 0
        case "", "#": delay = 0
        default: finish("bad line: \(line)"); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { run(lines, at: i + 1) } }
    }

    @MainActor private static func finish(_ status: String) {
        log.append(status)
        try? log.joined(separator: "\n").write(to: tmp.appendingPathComponent("herdr-mac-harness.log"), atomically: true, encoding: .utf8)
    }

    /// Through NSApp.sendEvent, as a real keypress: local monitors (WindowKeys), key
    /// equivalents, menus, keyDown. Without a key window (locked screen) only the monitors
    /// see it.
    @MainActor private static func press(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags) {
        guard let window else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: chars,
                                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                NSApp.sendEvent(e)
            }
        }
    }

    /// The Go menu's items: title, shortcut, enabled.
    @MainActor static func goMenu() -> String {
        guard let go = NSApp.mainMenu?.items.first(where: { $0.title == "Go" })?.submenu else { return "no Go menu" }
        go.update()
        return go.items.filter { !$0.isSeparatorItem }.map { i in
            "\(i.title)[\(i.keyEquivalentModifierMask.rawValue >> 16):\(i.keyEquivalent.debugDescription)]\(i.isEnabled ? "" : " DISABLED")"
        }.joined(separator: ", ")
    }

    /// "cmd+shift+]" → key code, characters as a US layout reports them, modifiers.
    private static func combo(_ s: String) -> (UInt16, String, NSEvent.ModifierFlags)? {
        var flags: NSEvent.ModifierFlags = []
        var parts = s.lowercased().split(separator: "+").map(String.init)
        guard let key = parts.popLast() else { return nil }
        for p in parts {
            switch p {
            case "cmd": flags.insert(.command)
            case "ctrl": flags.insert(.control)
            case "alt", "opt": flags.insert(.option)
            case "shift": flags.insert(.shift)
            default: return nil
            }
        }
        let shift = flags.contains(.shift)
        switch key {
        case "tab": return (48, "\t", flags)
        case "escape", "esc": return (53, "\u{1b}", flags)
        case "return", "enter": return (36, "\r", flags)
        case "]": return (30, shift ? "}" : "]", flags)
        case "[": return (33, shift ? "{" : "[", flags)
        case "/": return (44, shift ? "?" : "/", flags)
        default:
            guard key.count == 1, let (code, _) = keyFor(Character(key)) else { return nil }
            return (code, shift ? key.uppercased() : key, flags)
        }
    }

    private static let letters: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    ]
    private static let digits: [Character: UInt16] = ["1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29]

    private static func keyFor(_ c: Character) -> (UInt16, Bool)? {
        if let code = letters[Character(c.lowercased())] { return (code, c.isUppercase) }
        if let code = digits[c] { return (code, false) }
        switch c {
        case " ": return (49, false)
        case "-": return (27, false)
        case ".": return (47, false)
        case "=": return (24, false)
        default: return nil
        }
    }
}
#else
/// Release builds: no test hooks (signals, key injection, snapshots). A debug build has them
/// (`scripts/bundle.sh debug`).
enum DebugHarness {
    @MainActor static var selections: [Int: String] = [:]
    @MainActor static var navigate: ((Navigation) -> Void)?
    static func install() {}
    static func trace(_ line: String) {}
}
#endif
