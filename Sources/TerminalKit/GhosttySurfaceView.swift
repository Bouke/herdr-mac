import AppKit
import GhosttyKit
import HerdrCore

/// One libghostty terminal surface in an NSView: keyboard (with IME), mouse, scroll,
/// focus, size. A reduced port of Ghostty's own `SurfaceView_AppKit.swift` (MIT).
@MainActor
public final class GhosttySurfaceView: NSView, @preconcurrency NSTextInputClient {
    nonisolated(unsafe) public private(set) var surface: ghostty_surface_t?
    public var onClose: (() -> Void)?

    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var trackingArea: NSTrackingArea?
    private var cursorShape: NSCursor = .iBeam

    /// Runs `command` (argv) in libghostty's own pty.
    public init(command: [String], workingDirectory: String? = nil) {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        guard let app = GhosttyRuntime.shared.app else { return }
        var config = ghostty_surface_config_new()
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        config.font_size = 0
        config.wait_after_command = false
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        // libghostty runs this through `login … bash -c "exec -l <command>"`: quote each word.
        let commandLine = Shell.line(command)
        surface = commandLine.withCString { cCommand in
            (workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path).withCString { cDir in
                config.command = cCommand
                config.working_directory = cDir
                return ghostty_surface_new(app, &config)
            }
        }
        updateTrackingAreas()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Frees the surface (ends its pty program: `hc attach`, never the core terminal).
    public func close() {
        guard let surface else { return }
        self.surface = nil
        ghostty_surface_free(surface)
    }

    func surfaceDidClose() {
        close()
        onClose?()
    }

    /// Hidden (kept for quick switching): libghostty skips drawing it.
    public func setVisible(_ visible: Bool) {
        guard let surface else { return }
        ghostty_surface_set_occlusion(surface, visible)
    }

    func setCursor(_ shape: ghostty_action_mouse_shape_e) {
        cursorShape = switch shape {
        case GHOSTTY_MOUSE_SHAPE_POINTER: .pointingHand
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: .arrow
        default: .iBeam
        }
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Size and focus

    public override var acceptsFirstResponder: Bool { true }
    public override var isFlipped: Bool { false }

    public override func becomeFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, true) }
        return true
    }

    public override func resignFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, false) }
        return true
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateScale()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSize()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
    }

    private func updateScale() {
        guard let surface, let window else { return }
        layer?.contentsScale = window.backingScaleFactor
        let scale = convertToBacking(NSRect(x: 0, y: 0, width: 1, height: 1)).size
        ghostty_surface_set_content_scale(surface, scale.width, scale.height)
        updateSize()
    }

    private func updateSize() {
        guard let surface, bounds.width > 0, bounds.height > 0 else { return }
        let size = convertToBacking(bounds.size)
        ghostty_surface_set_size(surface, UInt32(size.width), UInt32(size.height))
    }

    public override func resetCursorRects() { addCursorRect(bounds, cursor: cursorShape) }

    public override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .activeAlways], owner: self)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    // MARK: Mouse

    private func mods(_ event: NSEvent) -> ghostty_input_mods_e { Self.mods(event.modifierFlags) }

    /// Mouse modifiers: while a program captures the mouse (Claude Code, vim...), libghostty
    /// only looks for links with Shift held (Shift means "not for the program"), so links
    /// took ⌘⇧-click. Here ⌘ alone is passed on as ⌘⇧ then: ⌘-click opens a link, as it
    /// does when nothing captures the mouse.
    private func mouseMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var f = flags
        if f.contains(.command), !f.contains(.shift), let surface, ghostty_surface_mouse_captured(surface) { f.insert(.shift) }
        return Self.mods(f)
    }

    /// Where the pointer last was in the view (top-left origin), to refresh link hover
    /// when ⌘ is pressed or released without moving the mouse.
    private var lastMouse: CGPoint?

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        button(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, event)
    }
    public override func mouseUp(with event: NSEvent) { button(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, event) }
    public override func rightMouseDown(with event: NSEvent) { button(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, event) }
    public override func rightMouseUp(with event: NSEvent) { button(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, event) }
    public override func otherMouseDown(with event: NSEvent) { button(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, event) }
    public override func otherMouseUp(with event: NSEvent) { button(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, event) }

    private func button(_ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e, _ event: NSEvent) {
        guard let surface else { return }
        mouseMoved(with: event)
        _ = ghostty_surface_mouse_button(surface, state, button, mouseMods(event.modifierFlags))
    }

    public override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let p = convert(event.locationInWindow, from: nil)
        lastMouse = CGPoint(x: p.x, y: bounds.height - p.y)
        ghostty_surface_mouse_pos(surface, p.x, bounds.height - p.y, mouseMods(event.modifierFlags))
    }
    public override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    public override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    public override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    public override func mouseExited(with event: NSEvent) {
        guard let surface, NSEvent.pressedMouseButtons == 0 else { return }
        lastMouse = nil
        ghostty_surface_mouse_pos(surface, -1, -1, mods(event))
    }

    public override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX, y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise { x *= 2; y *= 2 }
        let momentum: Int32 = switch event.momentumPhase {
        case .began: 1
        case .stationary: 2
        case .changed: 3
        case .ended: 4
        case .cancelled: 5
        case .mayBegin: 6
        default: 0
        }
        ghostty_surface_mouse_scroll(surface, x, y, (precise ? 1 : 0) | momentum << 1)
    }

    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        guard let surface else { interpretKeyEvents([event]); return }
        let translated = Self.flags(ghostty_surface_key_translation_mods(surface, mods(event)))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translated.contains(flag) { translationMods.insert(flag) } else { translationMods.remove(flag) }
        }
        let translationEvent: NSEvent = translationMods == event.modifierFlags ? event : NSEvent.keyEvent(
            with: event.type, location: event.locationInWindow, modifierFlags: translationMods,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: event.characters(byApplyingModifiers: translationMods) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        lastPerformKeyEvent = nil
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        let markedBefore = markedText.length > 0
        interpretKeyEvents([translationEvent])
        syncPreedit(clearIfNeeded: markedBefore)

        if let texts = keyTextAccumulator, !texts.isEmpty {
            for text in texts { _ = key(action, event, translationEvent: translationEvent, text: text) }
        } else {
            _ = key(action, event, translationEvent: translationEvent, text: Self.characters(translationEvent),
                    composing: markedText.length > 0 || markedBefore)
        }
    }

    public override func keyUp(with event: NSEvent) { _ = key(GHOSTTY_ACTION_RELEASE, event) }

    public override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }
        var pressed = mods(event).rawValue & mod != 0
        // With both sides held, releasing one still leaves the modifier set: check the side.
        if pressed {
            let side: UInt? = switch event.keyCode {
            case 0x3C: UInt(NX_DEVICERSHIFTKEYMASK)
            case 0x38: UInt(NX_DEVICELSHIFTKEYMASK)
            case 0x3E: UInt(NX_DEVICERCTLKEYMASK)
            case 0x3B: UInt(NX_DEVICELCTLKEYMASK)
            case 0x3D: UInt(NX_DEVICERALTKEYMASK)
            case 0x3A: UInt(NX_DEVICELALTKEYMASK)
            case 0x36: UInt(NX_DEVICERCMDKEYMASK)
            case 0x37: UInt(NX_DEVICELCMDKEYMASK)
            default: nil
            }
            if let side { pressed = event.modifierFlags.rawValue & side != 0 }
        }
        _ = key(pressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE, event)
        // ⌘ pressed or released over a link: underline it (or not) without a mouse move.
        if let surface, let p = lastMouse, event.keyCode == 0x37 || event.keyCode == 0x36 {
            ghostty_surface_mouse_pos(surface, p.x, p.y, mouseMods(event.modifierFlags))
        }
    }

    /// Whether this key is one of the terminal's own bindings (copy, paste...). A pure
    /// question: nothing is performed.
    public func isBinding(_ event: NSEvent) -> Bool {
        guard let surface else { return false }
        var ev = keyEvent(GHOSTTY_ACTION_PRESS, event)
        var flags = ghostty_binding_flags_e(0)
        return (event.characters ?? "").withCString { ptr in
            ev.text = ptr
            return ghostty_surface_key_is_binding(surface, ev, &flags)
        }
    }

    /// Timestamp of a ⌘/ctrl key the menu was offered first (see performKeyEquivalent).
    private var lastPerformKeyEvent: TimeInterval?

    /// ⌘/ctrl keys reach views before keyDown. The terminal's own bindings (copy, paste,
    /// font size...) are taken here; other ⌘ keys go to the app's menus first and come back
    /// a second time if no menu took them. ctrl+Return and ctrl+/ only ever arrive here.
    /// Follows Ghostty's own SurfaceView_AppKit. App keys (⌘Q, ⌘W, ⌘T...) aren't Ghostty
    /// bindings here: GhosttyRuntime's config starts with `keybind = clear`, so they reach the menus.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, let surface, window?.firstResponder === self else { return false }
        var ev = keyEvent(GHOSTTY_ACTION_PRESS, event)
        var flags = ghostty_binding_flags_e(0)
        let isBinding = (event.characters ?? "").withCString { ptr in
            ev.text = ptr
            return ghostty_surface_key_is_binding(surface, ev, &flags)
        }
        if isBinding {
            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"
        case "/":
            guard event.modifierFlags.contains(.control), event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else { return false }
            equivalent = "_"
        default:
            if event.timestamp == 0 { return false }
            guard event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) else {
                lastPerformKeyEvent = nil
                return false
            }
            if let last = lastPerformKeyEvent, last == event.timestamp {
                lastPerformKeyEvent = nil
                equivalent = event.characters ?? ""
            } else {
                lastPerformKeyEvent = event.timestamp
                return false
            }
        }
        guard let final = NSEvent.keyEvent(
            with: .keyDown, location: event.locationInWindow, modifierFlags: event.modifierFlags,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: equivalent, charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat, keyCode: event.keyCode) else { return false }
        keyDown(with: final)
        return true
    }

    private func key(_ action: ghostty_input_action_e, _ event: NSEvent, translationEvent: NSEvent? = nil,
                     text: String? = nil, composing: Bool = false) -> Bool {
        guard let surface else { return false }
        var ev = keyEvent(action, event, translationMods: translationEvent?.modifierFlags)
        ev.composing = composing
        if let text, let first = text.utf8.first, first >= 0x20 {
            return text.withCString { ptr in ev.text = ptr; return ghostty_surface_key(surface, ev) }
        }
        return ghostty_surface_key(surface, ev)
    }

    private func keyEvent(_ action: ghostty_input_action_e, _ event: NSEvent, translationMods: NSEvent.ModifierFlags? = nil) -> ghostty_input_key_s {
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.keycode = UInt32(event.keyCode)
        ev.text = nil
        ev.composing = false
        ev.mods = Self.mods(event.modifierFlags)
        ev.consumed_mods = Self.mods((translationMods ?? event.modifierFlags).subtracting([.control, .command]))
        ev.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp,
           let scalar = event.characters(byApplyingModifiers: [])?.unicodeScalars.first {
            ev.unshifted_codepoint = scalar.value
        }
        return ev
    }

    /// Text for a key event: control characters are encoded by Ghostty itself; function
    /// keys (private-use range) carry none.
    static func characters(_ event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 { return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control)) }
            if (0xF700...0xF8FF).contains(scalar.value) { return nil }
        }
        return characters
    }

    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var m = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { m |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { m |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { m |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { m |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { m |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { m |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { m |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { m |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(m)
    }

    static func flags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { f.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { f.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { f.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { f.insert(.command) }
        return f
    }

    // MARK: NSTextInputClient (IME)

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let s = markedText.string
            s.withCString { ghostty_surface_preedit(surface, $0, UInt(s.utf8.count)) }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    public func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        unmarkText()
        if var acc = keyTextAccumulator {
            acc.append(text)
            keyTextAccumulator = acc
            return
        }
        guard let surface else { return }
        text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
    }

    public override func doCommand(by selector: Selector) {}

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let s as NSAttributedString: markedText = NSMutableAttributedString(attributedString: s)
        case let s as String: markedText = NSMutableAttributedString(string: s)
        default: return
        }
        if keyTextAccumulator == nil { syncPreedit() }
    }

    public func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }

    public func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    public func markedRange() -> NSRange { markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0) }
    public func hasMarkedText() -> Bool { markedText.length > 0 }
    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    public func characterIndex(for point: NSPoint) -> Int { 0 }

    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface, let window else { return .zero }
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let local = NSRect(x: x, y: bounds.height - y, width: w, height: h)
        return window.convertToScreen(convert(local, to: nil))
    }
}
