import AppKit
import HerdrCore
import SwiftUI

/// `theme()` for mods: Herdr's color names, filled with macOS's own colors for the current
/// appearance, so a mod looks at home on the glass instead of painting Herdr's panels.
/// Backgrounds are clear: the window's material shows through.
struct ModTheme {
    let dark: Bool
    let colors: [String: String]

    init(dark: Bool) {
        self.dark = dark
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        func hex(_ c: NSColor, _ alpha: CGFloat = 1) -> String {
            var out = "#00000000"
            appearance.performAsCurrentDrawingAppearance {
                guard let rgb = c.usingColorSpace(.sRGB) else { return }
                let a = rgb.alphaComponent * alpha
                // Opaque colors as #rrggbb, as Herdr gives them: mods add their own alpha
                // (`t.ansi2 + "18"`), which only works on six digits.
                out = String(format: "#%02x%02x%02x", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
                if a < 0.999 { out += String(format: "%02x", Int(a * 255)) }
            }
            return out
        }
        var c: [String: String] = [
            "background": "#00000000", "canvas": "#00000000", "chrome": "#00000000", "surface": "#00000000",
            "popover": hex(.windowBackgroundColor),
            "raised": hex(.labelColor, 0.06), "hover": hex(.labelColor, 0.08), "selected": hex(.controlAccentColor, 0.2),
            "border": hex(.separatorColor), "input": hex(.labelColor, 0.22),
            "foreground": hex(.labelColor), "muted": hex(.secondaryLabelColor), "dim": hex(.tertiaryLabelColor),
            "accent": hex(.controlAccentColor), "accent_foreground": "#ffffffff",
            "solid": hex(.controlAccentColor), "solid_foreground": "#ffffffff", "selection": hex(.selectedTextBackgroundColor),
            "working": hex(.systemBlue), "blocked": hex(.systemOrange), "done": hex(.systemGreen),
            "idle": hex(.tertiaryLabelColor), "unknown": hex(.secondaryLabelColor),
        ]
        let ansi: [NSColor] = [.black, .systemRed, .systemGreen, .systemYellow, .systemBlue, .systemPurple, .systemTeal, .lightGray,
                               .darkGray, .systemRed, .systemGreen, .systemYellow, .systemBlue, .systemPurple, .systemTeal, .white]
        for (i, color) in ansi.enumerated() { c["ansi\(i)"] = hex(color) }
        colors = c
    }

    var json: JSON { .object(colors.mapValues { .string($0) }) }
    var border: Color { color(.string(colors["border"]!)) ?? .gray }

    /// `#rrggbb`, `#rrggbbaa` or a theme name.
    func color(_ j: JSON) -> Color? {
        guard var s = j.string else { return nil }
        if let named = colors[s] { s = named }
        // "#rrggbbaa" + "aa" (a mod's alpha on a translucent theme color): keep the color, use the last alpha.
        if s.hasPrefix("#"), s.count == 11 { s = String(s.prefix(7)) + String(s.suffix(2)) }
        guard s.hasPrefix("#"), let v = UInt64(s.dropFirst(), radix: 16) else { return s == "transparent" ? .clear : nil }
        let has8 = s.count == 9
        let r = Double((v >> (has8 ? 24 : 16)) & 0xff) / 255, g = Double((v >> (has8 ? 16 : 8)) & 0xff) / 255
        let b = Double((v >> (has8 ? 8 : 0)) & 0xff) / 255, a = has8 ? Double(v & 0xff) / 255 : 1
        return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
