import Foundation
import Testing
@testable import HerdrCore

private let noThemes = URL(fileURLWithPath: "/nonexistent")

@Test func herdrDefaultsBecomeGhosttyConfig() {
    let c = HerdrSettings([:]).ghosttyConfig(dark: true, themesDir: noThemes)
    #expect(c.contains("font-size = 14"))
    #expect(c.contains("font-style = Medium"))
    #expect(c.contains("font-style-bold = Bold"))
    #expect(c.contains("font-feature = -calt"), "ligatures are off by default, as in Herdr")
    #expect(c.contains("background = #17191d"), "graphite when dark")
    #expect(HerdrSettings([:]).ghosttyConfig(dark: false, themesDir: noThemes).contains("background = #ffffff"), "paper when light")
}

@Test func personalSettingsMap() {
    let s = HerdrSettings(["font": "Geist Mono", "font_size": 13, "zoom": 1.5, "font_weight": 300, "font_ligatures": true,
                           "terminal_line_height": 1.2, "terminal_cell_width": 0.95, "option_as_alt": "left",
                           "copy_on_select": false, "minimum_contrast": 1.6])
    let c = s.ghosttyConfig(dark: true, themesDir: noThemes)
    #expect(c.contains("font-family = Geist Mono"))
    #expect(c.contains("font-size = 19.50"))
    #expect(c.contains("font-style = Light"))
    #expect(!c.contains("font-feature"))
    #expect(c.contains("adjust-cell-height = 20%"))
    #expect(c.contains("adjust-cell-width = -5%"))
    #expect(c.contains("macos-option-as-alt = left"))
    #expect(c.contains("copy-on-select = false"))
    #expect(c.contains("minimum-contrast = 1.60"))
}

@Test func themesFollowAppearanceAndFiles() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("themes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let ansi = (0..<16).map { _ in "\"#010203\"" }.joined(separator: ",")
    try ##"{"background":"#123456","foreground":"#abcdef","selection":"#222222","ansi":[\##(ansi)]}"##
        .write(to: dir.appendingPathComponent("mine.json"), atomically: true, encoding: .utf8)
    let s = HerdrSettings(["theme": ["light": "paper", "dark": "mine"]])
    #expect(s.ghosttyConfig(dark: true, themesDir: dir).contains("background = #123456"))
    #expect(s.ghosttyConfig(dark: false, themesDir: dir).contains("background = #ffffff"))
    #expect(HerdrSettings(["theme": "ink"]).ghosttyConfig(dark: false, themesDir: dir).contains("background = #111720"))
    #expect(HerdrSettings(["theme": "missing"]).ghosttyConfig(dark: true, themesDir: dir).contains("background = #17191d"))
    #expect(HerdrSettings(["appearance": "light"]).forcedDark == false)
    #expect(HerdrSettings([:]).forcedDark == nil)
}

@Test func unreadableSettingsKeepTheLastGoodOnes() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("settings.json")
    #expect(HerdrSettings.read(file) == HerdrSettings(), "no file: Herdr's defaults")
    try #"{"font_size": 15"#.write(to: file, atomically: true, encoding: .utf8)
    #expect(HerdrSettings.read(file) == nil, "half-written: keep what we have")
    try "[1]".write(to: file, atomically: true, encoding: .utf8)
    #expect(HerdrSettings.read(file) == nil)
    try #"{"font_size": 15}"#.write(to: file, atomically: true, encoding: .utf8)
    #expect(HerdrSettings.read(file)?.raw["font_size"].int == 15)
}

@Test func herdrSendBindingsBecomeGhosttyKeybinds() throws {
    let keys = HerdrKeys(try JSON.parse(Data(#"""
    {"global": {"cmd-t": "tab.new", "cmd-k": "send:clear\r", "cmd--": "send:x"},
     "terminal": {"alt-backspace": "send:\u0017", "alt-left": "send:\u001bb", "cmd-left": "send:\u0001",
                  "cmd-k": "send:\u000c", "ctrl-1": "terminal", "hyper-x": "send:y", "ctrl-pageup": "send:é"}}
    """#.utf8)))
    let binds = keys.ghosttyKeybinds()
    #expect(binds.contains(#"keybind = alt+backspace=text:\x17"#))
    #expect(binds.contains(#"keybind = alt+left=text:\x1bb"#))
    #expect(binds.contains(#"keybind = super+left=text:\x01"#))
    #expect(binds.contains(#"keybind = super+k=text:\x0c"#), "terminal wins over global")
    #expect(binds.contains(#"keybind = super+minus=text:x"#))
    #expect(binds.contains(#"keybind = ctrl+page_up=text:\u{e9}"#))
    #expect(!binds.contains { $0.contains("super+t") || $0.contains("ctrl+1") || $0.contains("hyper") },
            "only send: bindings, and only keys Ghostty can name")
}
