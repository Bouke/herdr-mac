import AppKit
import HerdrCore
import SwiftUI

/// One element a mod's `render()` described: what gpui-kit lite recorded.
struct ModNode {
    struct Call { let name: String; let args: [JSON] }

    var kind: String?          // div, v, h, svg, image; nil for text
    var arg: String?           // svg/image path
    var text: String?
    var calls: [Call] = []
    var hover: [Call]?
    var click: Int?
    var children: [ModNode] = []

    init(_ json: JSON) {
        if let t = json["t"].string { text = t; return }
        kind = json["k"].string
        arg = json["a"].string
        calls = Self.calls(json["s"])
        hover = json["h"].isNull ? nil : Self.calls(json["h"])
        click = json["on"].int
        children = (json["c"].array ?? []).map(ModNode.init)
    }

    static func calls(_ json: JSON) -> [Call] {
        (json.array ?? []).compactMap { c in
            guard let pair = c.array, let name = pair.first?.string else { return nil }
            return Call(name: name, args: pair.count > 1 ? pair[1].array ?? [] : [])
        }
    }
}

/// Text properties that children inherit (as CSS's color, font-size, white-space do).
struct ModText {
    var color: Color = .primary
    var size: CGFloat = 13
    var weight: Font.Weight = .regular
    var italic = false
    var mono = false
    var lines: Int? = nil
    var align: Alignment = .leading
}

enum ModDim { case px(CGFloat), percent(CGFloat) }

/// A node's style, from its builder calls (GPUI's names, Tailwind-like).
struct ModStyle {
    enum Align { case start, center, end, stretch }
    enum Justify { case start, center, end, between }

    var row: Bool?
    var align: Align?
    var justify: Justify = .start
    var gap: CGFloat = 0
    var pad = EdgeInsets(), margin = EdgeInsets()
    var width: ModDim?, height: CGFloat?, maxWidth: CGFloat?
    var fillW = false, fillH = false, flex1 = false
    var bg: Color?, opacity: Double?
    var radius: CGFloat = 0
    var border: CGFloat = 0, edges: [Edge: CGFloat] = [:], borderColor: Color?
    var scroll = false, scrollX = false, clip = false, invisible = false
    /// `min_h(0)`: may be shorter than its content (CSS flex items can't, without it).
    var shrinkH = false
    var minWidth: CGFloat?
    var tooltip: String?
    var text = TextOverrides()

    struct TextOverrides { var color: Color?, size: CGFloat?, weight: Font.Weight?, italic: Bool?, mono: Bool?, lines: Int?, align: Alignment? }

    var isPercentWidth: Bool { if case .percent = width { return true }; return false }

    /// `absolute()`: drawn over the parent's box at `top`/`left` (or `right`/`bottom`),
    /// outside the flow, as in CSS.
    var absolute = false
    var top: CGFloat?, left: CGFloat?, right: CGFloat?, bottom: CGFloat?

    init(_ calls: [ModNode.Call], theme: ModTheme) { apply(calls, theme: theme) }

    mutating func apply(_ calls: [ModNode.Call], theme: ModTheme) {
        for c in calls {
            let n = c.args.first.flatMap(Self.number) ?? 0
            switch c.name {
            case "flex", "flex_row": row = true
            case "flex_col": row = false
            case "items_start": align = .start
            case "items_center": align = .center
            case "items_end": align = .end
            case "items_stretch": align = .stretch
            case "justify_start": justify = .start
            case "justify_center": justify = .center
            case "justify_end": justify = .end
            case "justify_between", "justify_around", "justify_evenly": justify = .between
            case "gap", "gap_x", "gap_y": gap = n
            case "p": pad = EdgeInsets(top: n, leading: n, bottom: n, trailing: n)
            case "px": pad.leading = n; pad.trailing = n
            case "py": pad.top = n; pad.bottom = n
            case "pt": pad.top = n
            case "pb": pad.bottom = n
            case "pl": pad.leading = n
            case "pr": pad.trailing = n
            case "m": margin = EdgeInsets(top: n, leading: n, bottom: n, trailing: n)
            case "mx": margin.leading = n; margin.trailing = n
            case "my": margin.top = n; margin.bottom = n
            case "mt": margin.top = n
            case "mb": margin.bottom = n
            case "ml": margin.leading = n
            case "mr": margin.trailing = n
            case "w": width = c.args.first.flatMap(Self.dim)
            case "h": height = n
            case "size": width = .px(n); height = n
            case "max_w": maxWidth = n
            case "w_full": fillW = true
            case "h_full": fillH = true
            case "size_full": fillW = true; fillH = true
            case "flex_1", "flex_grow": flex1 = true
            case "bg": bg = c.args.first.flatMap(theme.color)
            case "opacity": opacity = Double(n)
            case "rounded": radius = n
            case "rounded_sm": radius = 2
            case "rounded_md": radius = 6
            case "rounded_lg": radius = 8
            case "rounded_xl": radius = 12
            case "rounded_full": radius = 999
            case "border", "border_1": border = c.args.isEmpty ? 1 : n
            case "border_2": border = 2
            case "border_t", "border_t_1": edges[.top] = c.args.isEmpty ? 1 : n
            case "border_b", "border_b_1": edges[.bottom] = c.args.isEmpty ? 1 : n
            case "border_l", "border_l_1": edges[.leading] = c.args.isEmpty ? 1 : n
            case "border_r", "border_r_1": edges[.trailing] = c.args.isEmpty ? 1 : n
            case "border_color": borderColor = c.args.first.flatMap(theme.color)
            case "text_color": text.color = c.args.first.flatMap(theme.color)
            case "text_size": text.size = n
            case "text_xs": text.size = 12
            case "text_sm": text.size = 14
            case "text_base": text.size = 16
            case "text_lg": text.size = 18
            case "text_xl": text.size = 20
            case "font_weight": text.weight = Self.weight(Int(n))
            case "font_light": text.weight = .light
            case "font_normal": text.weight = .regular
            case "font_medium": text.weight = .medium
            case "font_semibold": text.weight = .semibold
            case "font_bold": text.weight = .bold
            case "italic": text.italic = true
            case "font_family": text.mono = (c.args.first?.string ?? "").lowercased().contains("mono")
            case "truncate", "whitespace_nowrap", "text_ellipsis": text.lines = 1
            case "line_clamp": text.lines = Int(n)
            case "overflow_y_scroll", "overflow_y_scrollbar": scroll = true
            case "overflow_x_scroll", "overflow_x_scrollbar": scrollX = true
            case "overflow_scroll", "overflow_scrollbar": scroll = true; scrollX = true
            case "min_h": shrinkH = n == 0
            case "min_w": if n > 0 { minWidth = n }
            case "overflow_hidden": clip = true
            case "invisible": invisible = true
            case "absolute": absolute = true
            case "top": top = n
            case "left": left = n
            case "right": right = n
            case "bottom": bottom = n
            case "inset_0": top = 0; left = 0; right = 0; bottom = 0
            case "text_left": text.align = .leading
            case "text_center": text.align = .center
            case "text_right": text.align = .trailing
            case "tooltip": tooltip = c.args.first?.string
            default: break // cursor_pointer, min_w, flex_none, absolute... have no SwiftUI meaning here
            }
        }
    }

    static func number(_ j: JSON) -> CGFloat? {
        if let d = j.double { return CGFloat(d) }
        if let s = j.string, let d = Double(s.replacingOccurrences(of: "px", with: "")) { return CGFloat(d) }
        return nil
    }

    static func dim(_ j: JSON) -> ModDim? {
        if let s = j.string, s.hasSuffix("%"), let d = Double(s.dropLast()) { return .percent(CGFloat(d) / 100) }
        return number(j).map { .px($0) }
    }

    static func weight(_ w: Int) -> Font.Weight {
        switch w { case ..<350: .light; case ..<450: .regular; case ..<550: .medium; case ..<650: .semibold; default: .bold }
    }
}

/// Draws a mod's tree with SwiftUI.
struct ModNodeView: View {
    let node: ModNode
    let inherited: ModText
    let theme: ModTheme
    /// The parent stacks children vertically and stretches them (block/v_flex default).
    let stretch: Bool
    let parentRow: Bool
    let click: (Int) -> Void
    /// A text field's event: (input id, "change" | "submit" | "focus" | "blur", value).
    var input: (Int, String, String) -> Void = { _, _, _ in }
    @State private var hovered = false

    var body: some View {
        if let text = node.text {
            textView(text, inherited)
                .frame(maxWidth: stretch ? .infinity : nil, alignment: inherited.align)
        } else {
            element
        }
    }

    private var style: ModStyle {
        var s = ModStyle(node.calls, theme: theme)
        if hovered, let h = node.hover { s.apply(h, theme: theme) }
        return s
    }

    private func textView(_ s: String, _ t: ModText) -> some View {
        var font = Font.system(size: t.size, weight: t.weight, design: t.mono ? .monospaced : .default)
        if t.italic { font = font.italic() }
        return Text(s).font(font).foregroundStyle(t.color)
            .multilineTextAlignment(t.align == .trailing ? .trailing : t.align == .center ? .center : .leading)
            .lineLimit(t.lines).truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: t.lines == nil)
    }

    /// Built step by step, each step only where the element uses it: every modifier is a
    /// few graph nodes SwiftUI updates on each frame of a window resize, times every element
    /// of every mod. (Type-erased: the steps depend on the element.)
    private var element: AnyView {
        let s = style
        let t = textStyle(s)
        var v = AnyView(AnyView(content(s, t)).padding(s.pad))
        if s.scroll && s.scrollX {
            v = AnyView(ScrollView([.vertical, .horizontal]) { v })
        } else if s.scroll {
            let inner = v
            v = AnyView(ScrollView(.vertical) { inner.frame(maxWidth: .infinity, alignment: .topLeading) })
        } else if s.scrollX {
            let inner = v
            v = AnyView(ScrollView(.horizontal) { inner.frame(maxHeight: .infinity, alignment: .topLeading) })
        }
        // In a column, a growing box takes what's left and no more (flex: 1 1 0 with min-height
        // 0, as Herdr's mods write it): it may be shorter than its content, which is cut off or
        // scrolls. Without this a long list makes the whole window taller than the screen.
        let shrinks = !parentRow && (s.flex1 || s.shrinkH || s.fillH) || s.scroll || node.kind == "vlist"
        let fixedWidth: CGFloat? = { if case .px(let w) = s.width { return w }; return nil }()
        if fixedWidth != nil || s.height != nil { v = AnyView(v.frame(width: fixedWidth, height: s.height)) }
        // Stretched (block in a column), grown or full: wide before painting, so the
        // background and borders cover the whole box, as in CSS.
        v = AnyView(v.frame(minWidth: s.minWidth,
                            maxWidth: s.fillW || (s.flex1 && parentRow) || (stretch && s.width == nil) || s.isPercentWidth ? .infinity : s.maxWidth,
                            minHeight: shrinks ? 0 : nil,
                            maxHeight: s.fillH || (s.flex1 && !parentRow) || node.kind == "vlist" ? .infinity : nil,
                            alignment: t.align == .trailing ? .trailing : node.kind == "h" || s.row == true ? .leading : .topLeading))
        if shrinks { v = AnyView(v.clipped()) }
        // Positioned children cover the whole (sized) box, padding included, as CSS's
        // containing block; on the content alone an empty box would give them no room.
        if hasPositioned { v = AnyView(v.overlay(alignment: .topLeading) { AnyView(positioned(s, t)) }) }
        let shape = RoundedRectangle(cornerRadius: s.radius, style: .continuous)
        if let bg = s.bg { v = AnyView(v.background { shape.fill(bg) }) }
        if s.clip && s.radius > 0 { v = AnyView(v.clipShape(shape)) }
        if s.border > 0 { v = AnyView(v.overlay { shape.strokeBorder(s.borderColor ?? theme.border, lineWidth: s.border) }) }
        if !s.edges.isEmpty { v = AnyView(v.overlay { edges(s) }) }
        if s.invisible || s.opacity != nil { v = AnyView(v.opacity(s.invisible ? 0 : s.opacity ?? 1)) }
        if s.margin != EdgeInsets() { v = AnyView(v.padding(s.margin)) }
        if case .percent(let f) = s.width { let inner = v; v = AnyView(FractionWidth(fraction: f) { inner }) }
        // In a row, a block is as wide as its content (CSS), unless it grows: without this,
        // stretched text inside would make it take an equal share of the row.
        if parentRow && !s.flex1 && !s.fillW && s.width == nil { v = AnyView(v.fixedSize(horizontal: true, vertical: false)) }
        if let tip = s.tooltip { v = AnyView(v.help(tip)) }
        if node.hover != nil { v = AnyView(v.onHover { inside in hovered = inside }) }
        if let id = node.click { v = AnyView(v.contentShape(Rectangle()).onTapGesture { click(id) }) }
        return v
    }

    private var hasPositioned: Bool {
        node.children.contains { $0.text == nil && $0.calls.contains { $0.name == "absolute" } }
    }

    /// One-sided borders (`border_t(1)`...), in one overlay.
    private func edges(_ s: ModStyle) -> some View {
        ZStack {
            edge(s, .top).frame(maxHeight: .infinity, alignment: .top)
            edge(s, .bottom).frame(maxHeight: .infinity, alignment: .bottom)
            edge(s, .leading).frame(maxWidth: .infinity, alignment: .leading)
            edge(s, .trailing).frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// What this element's text looks like: inherited, then its own overrides.
    private func textStyle(_ s: ModStyle) -> ModText {
        var t = inherited
        if let c = s.text.color { t.color = c }
        if let v = s.text.size { t.size = v }
        if let w = s.text.weight { t.weight = w }
        if let i = s.text.italic { t.italic = i }
        if let m = s.text.mono { t.mono = m }
        if let l = s.text.lines { t.lines = l }
        if let a = s.text.align { t.align = a }
        return t
    }

    @ViewBuilder private func edge(_ s: ModStyle, _ e: Edge) -> some View {
        if let w = s.edges[e], w > 0 {
            let line = Rectangle().fill(s.borderColor ?? theme.border)
            if e == .top || e == .bottom { line.frame(height: w) } else { line.frame(width: w) }
        }
    }

    @ViewBuilder private func content(_ s: ModStyle, _ t: ModText) -> some View {
        switch node.kind {
        case "none":
            EmptyView()
        case "vlist":
            // A virtual list scrolls itself; lazily, so thousands of rows cost only what shows.
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: s.gap) { children(s, t, row: false, stretch: true) }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        case "input":
            if let call = node.calls.first(where: { $0.name == "__input" }), let id = call.args.first?.int {
                ModTextField(id: id, placeholder: call.args.count > 1 ? call.args[1].string ?? "" : "",
                             value: call.args.count > 2 ? call.args[2].string ?? "" : "", style: t, send: input)
            }
        case "svg", "image":
            ModImage(path: node.arg, template: node.kind == "svg", color: t.color,
                     size: { if case .px(let w) = s.width { return w }; return s.height ?? t.size }())
        default:
            let row = s.row ?? (node.kind == "h")
            if row {
                let align: VerticalAlignment = switch s.align ?? (node.kind == "h" ? .center : .start) {
                case .center: .center
                case .end: .bottom
                default: .top
                }
                HStack(alignment: align, spacing: s.gap) { children(s, t, row: true, stretch: false) }
            } else {
                let align: HorizontalAlignment = switch s.align ?? .stretch {
                case .center: .center
                case .end: .trailing
                default: .leading
                }
                VStack(alignment: align, spacing: s.gap) { children(s, t, row: false, stretch: (s.align ?? .stretch) == .stretch) }
            }
        }
    }

    /// Children with `absolute()`, over this box (padding included, as CSS's containing block).
    @ViewBuilder private func positioned(_ s: ModStyle, _ t: ModText) -> some View {
        let kids = node.children.enumerated().filter { ModStyle($0.element.calls, theme: theme).absolute }
        if !kids.isEmpty {
            ZStack(alignment: .topLeading) {
                ForEach(kids, id: \.offset) { _, child in
                    let cs = ModStyle(child.calls, theme: theme)
                    ModNodeView(node: child, inherited: t, theme: theme, stretch: false, parentRow: false, click: click, input: input)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: Alignment(horizontal: cs.right != nil && cs.left == nil ? .trailing : .leading,
                                                    vertical: cs.bottom != nil && cs.top == nil ? .bottom : .top))
                        .offset(x: cs.left ?? -(cs.right ?? 0), y: cs.top ?? -(cs.bottom ?? 0))
                }
            }
        }
    }

    @ViewBuilder private func children(_ s: ModStyle, _ t: ModText, row: Bool, stretch: Bool) -> some View {
        let kids = Array(node.children.enumerated()).filter { $0.element.text != nil || !ModStyle($0.element.calls, theme: theme).absolute }
        if s.justify == .end || s.justify == .center { Spacer(minLength: 0) }
        ForEach(kids, id: \.offset) { i, child in
            if s.justify == .between && i > 0 { Spacer(minLength: 0) }
            ModNodeView(node: child, inherited: t, theme: theme, stretch: stretch, parentRow: row, click: click, input: input)
        }
        if s.justify == .center { Spacer(minLength: 0) }
    }
}


/// `w("37%")`: a share of the width the parent offers.
private struct FractionWidth: Layout {
    let fraction: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = (proposal.width ?? 0) * fraction
        let h = subviews.first?.sizeThatFits(ProposedViewSize(width: w, height: proposal.height)).height ?? 0
        return CGSize(width: proposal.width ?? w, height: h)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width * fraction, height: bounds.height))
    }
}

/// `svg("mods/x/icon.svg")` (tinted with the text color) or `image(...)`, from the Herdr home.
private struct ModImage: View {
    let path: String?
    let template: Bool
    let color: Color
    let size: CGFloat

    var body: some View {
        if let image = path.flatMap(Self.load) {
            Image(nsImage: image).renderingMode(template ? .template : .original).resizable().scaledToFit()
                .foregroundStyle(color).frame(width: size, height: size)
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }

    static func load(_ path: String) -> NSImage? {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : ModHost.appHome.appendingPathComponent(path)
        return NSImage(contentsOf: url)
    }
}

/// `Input.new(state)`: a native text field. The mod's InputState holds the text; edits go
/// back as "change", Return as "submit", and focus changes as "focus"/"blur".
private struct ModTextField: View {
    let id: Int
    let placeholder: String
    let value: String
    let style: ModText
    let send: (Int, String, String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: style.size))
            .foregroundStyle(style.color)
            .focused($focused)
            .onAppear { text = value }
            // The mod changed it (set_value after a commit): follow, unless it's what we sent.
            .onChange(of: value) { _, new in if new != text { text = new } }
            .onChange(of: text) { _, new in if new != value { send(id, "change", new) } }
            .onSubmit { send(id, "submit", text) }
            .onChange(of: focused) { _, f in send(id, f ? "focus" : "blur", text) }
    }
}
