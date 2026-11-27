import Foundation

/// The person's Herdr settings (`~/.config/herdr-app/settings.json`), the same file
/// herdr-app reads, turned into Ghostty config so both apps look and type alike.
public struct HerdrSettings: Equatable, Sendable {
    public var raw: JSON

    public init(_ raw: JSON = [:]) { self.raw = raw }

    /// herdr-app's settings.json; `HERDR_MAC_SETTINGS` points elsewhere (for testing).
    public static let defaultURL = ProcessInfo.processInfo.environment["HERDR_MAC_SETTINGS"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/herdr-app/settings.json")

    /// The settings, or empty (Herdr's defaults) when there's no file or it can't be read.
    public static func load(_ url: URL = defaultURL) -> HerdrSettings { read(url) ?? HerdrSettings() }

    /// nil when the file exists but isn't a valid settings object (half-written, a typo):
    /// callers keep their last good settings then, as herdr-app does.
    public static func read(_ url: URL = defaultURL) -> HerdrSettings? {
        guard let data = try? Data(contentsOf: url) else {
            return FileManager.default.fileExists(atPath: url.path) ? nil : HerdrSettings()
        }
        guard let json = try? JSON.parse(data), json.object != nil else { return nil }
        return HerdrSettings(json)
    }

    /// `appearance`: "light" / "dark" forces one; absent follows the system.
    public var forcedDark: Bool? {
        switch raw["appearance"].string { case "dark": true; case "light": false; default: nil }
    }

    /// The theme for this appearance: `theme` as a name or `{light, dark}`; Herdr's defaults
    /// are graphite (dark) and paper (light).
    public func themeName(dark: Bool) -> String {
        let t = raw["theme"]
        if let name = t.string { return name }
        if let name = t[dark ? "dark" : "light"].string { return name }
        return dark ? "graphite" : "paper"
    }

    /// Ghostty config lines for these settings. `themesDir` holds the person's
    /// `themes/<name>.json` (herdr-app's format).
    public func ghosttyConfig(dark: Bool, themesDir: URL) -> String {
        var lines: [String] = []
        let zoom = raw["zoom"].double ?? 1
        if let font = raw["font"].string, !font.isEmpty {
            lines.append("font-family = \"\"")
            lines.append("font-family = \(font)")
        }
        lines.append("font-size = \(format((raw["font_size"].double ?? 14) * zoom))")
        lines.append("font-style = \(Self.style(raw["font_weight"].int ?? 500))")
        lines.append("font-style-bold = \(Self.style(raw["font_weight_bold"].int ?? 700))")
        if raw["font_ligatures"].bool != true {
            lines += ["font-feature = -calt", "font-feature = -liga", "font-feature = -dlig"]
        }
        if let h = raw["terminal_line_height"].double, h != 1 {
            lines.append("adjust-cell-height = \(format((min(max(h, 0.8), 2) - 1) * 100))%")
        }
        if let w = raw["terminal_cell_width"].double, w != 1 {
            lines.append("adjust-cell-width = \(format((min(max(w, 0.8), 2) - 1) * 100))%")
        }
        if let s = raw["terminal_scroll_speed"].double {
            lines.append("mouse-scroll-multiplier = \(format(min(max(s, 0.1), 5)))")
        }
        if let c = raw["minimum_contrast"].double { lines.append("minimum-contrast = \(format(min(max(c, 1), 21)))") }
        switch raw["option_as_alt"].string {
        case "on": lines.append("macos-option-as-alt = true")
        case "off": lines.append("macos-option-as-alt = false")
        case "left": lines.append("macos-option-as-alt = left")
        case "right": lines.append("macos-option-as-alt = right")
        default: break
        }
        lines.append("copy-on-select = \(raw["copy_on_select"].bool == false ? "false" : "clipboard")")
        let palette = Self.palette(themeName(dark: dark), themesDir: themesDir) ?? (dark ? Self.presets["graphite"]! : Self.presets["paper"]!)
        lines += palette.ghosttyLines
        return lines.joined(separator: "\n")
    }

    static func style(_ weight: Int) -> String {
        switch weight {
        case ..<150: "Thin"
        case ..<250: "ExtraLight"
        case ..<350: "Light"
        case ..<450: "Regular"
        case ..<550: "Medium"
        case ..<650: "SemiBold"
        case ..<750: "Bold"
        case ..<850: "ExtraBold"
        default: "Black"
        }
    }

    /// Two decimals at most, whole numbers without (`(1.2 - 1) * 100` is 19.999…: "20").
    private func format(_ v: Double) -> String {
        let r = (v * 100).rounded() / 100
        return r.rounded() == r ? String(Int(r)) : String(format: "%.2f", r)
    }

    // MARK: Palettes (Herdr's presets, from herdr-app src/settings.rs)

    public struct Palette: Equatable, Sendable {
        var background: String, foreground: String, selection: String, cursor: String?, ansi: [String]

        var ghosttyLines: [String] {
            var l = ["background = \(background)", "foreground = \(foreground)", "selection-background = \(selection)"]
            if let cursor { l.append("cursor-color = \(cursor)") }
            l += ansi.enumerated().map { "palette = \($0.offset)=\($0.element)" }
            return l
        }
    }

    static func palette(_ name: String, themesDir: URL) -> Palette? {
        if let p = presets[name] { return p }
        let file = themesDir.appendingPathComponent("\(name).json")
        guard let data = try? Data(contentsOf: file), let t = try? JSON.parse(data),
              let bg = t["background"].string, let fg = t["foreground"].string, let sel = t["selection"].string,
              let ansi = t["ansi"].array?.compactMap(\.string), ansi.count == 16 else { return nil }
        return Palette(background: bg, foreground: fg, selection: sel, cursor: t["cursor"].string, ansi: ansi)
    }

    private static func hex(_ v: [UInt32]) -> [String] { v.map { String(format: "#%06x", $0) } }
    private static func p(_ bg: UInt32, _ fg: UInt32, _ sel: UInt32, _ cursor: UInt32?, _ ansi: [UInt32]) -> Palette {
        Palette(background: hex([bg])[0], foreground: hex([fg])[0], selection: hex([sel])[0], cursor: cursor.map { hex([$0])[0] }, ansi: hex(ansi))
    }

    static let presets: [String: Palette] = [
        "graphite": p(0x17191d, 0xd2d4d9, 0x394454, nil, [
            0x45484f, 0xdc8c95, 0xa6bd91, 0xd8be87, 0x96b2d7, 0xb5a2ce, 0x8cbdc3, 0xd2d4d9,
            0x818793, 0xf0a5ad, 0xbad5a2, 0xead2a1, 0xb0cbef, 0xcbb7e6, 0xa4d5db, 0xf0f0f2]),
        "ink": p(0x111720, 0xcdd6e4, 0x344861, nil, [
            0x414b5a, 0xe58c9a, 0x89c5aa, 0xd9be82, 0x91b6ee, 0xb9a0e2, 0x85c4d0, 0xcdd6e4,
            0x7f91a7, 0xf5a5b2, 0xa5dec3, 0xedd39c, 0xaccbfa, 0xd0b7f4, 0xa0dce5, 0xf0f5fc]),
        "moss": p(0x151c19, 0xcdd7ce, 0x354a40, nil, [
            0x435248, 0xdf978d, 0xa0c4a2, 0xd4bc8b, 0x99b9cd, 0xbba4c8, 0x8bbdb5, 0xcdd7ce,
            0x82968a, 0xf1afa3, 0xb8dab9, 0xe9d2a5, 0xb1d0e2, 0xd1bddc, 0xa4d6ca, 0xeff5ee]),
        "paper": p(0xffffff, 0x25272c, 0xcfdcf5, 0x25272c, [
            0x25272c, 0xc62a2a, 0x1a7f37, 0x8f5d00, 0x1f62d0, 0x7a45c8, 0x0f6f74, 0x5f6068,
            0x7b7e87, 0xd1242f, 0x1f883d, 0x9a6700, 0x0969da, 0x8250df, 0x1b7c83, 0x111214]),
    ]
}
