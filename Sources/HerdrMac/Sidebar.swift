import AppKit
import HerdrCore
import SwiftUI

/// Herdr's spaces as sections, each tab's terminals as rows, then terminals no tab shows.
struct Sidebar: View {
    @Environment(HerdrStore.self) private var store
    @Environment(Look.self) private var look
    @Binding var selection: String?

    var body: some View {
        // Mods placed in the sidebar sit under the list, as a sidebar block does in Herdr.
        VStack(spacing: 0) {
            // Switching tabs (keys, ⌘W, a tab that ended) brings the new one into view;
            // anchor nil scrolls only as far as needed, so a visible row stays put.
            ScrollViewReader { proxy in
                list.onChange(of: selection) { _, address in
                    guard let address else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(address, anchor: nil) }
                }
            }
            SidebarMods()
        }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(store.spaces) { space in
                Section {
                    ForEach(space.tabs) { tab in
                        ForEach(tab.terminals.filter { store.terminals[$0]?.isLive == true }, id: \.self) { address in
                            TerminalRow(terminal: store.terminals[address]!, tab: tab, split: tab.terminals.count > 1)
                                .tag(address)
                                .id(address)
                        }
                    }
                } header: {
                    // The space's most urgent state right after its name: a header has
                    // other insets than its rows, so a trailing mark never lines up.
                    HStack(spacing: 5) {
                        Text(store.displayName(space))
                        StatusMark(state: store.state(of: space.tabs.flatMap(\.terminals)))
                            .imageScale(.small)
                    }
                }
            }
            let loose = store.looseTerminals
            if !loose.isEmpty {
                Section("Other terminals") {
                    ForEach(loose) { t in
                        TerminalRow(terminal: t, tab: nil, split: false).tag(t.address).id(t.address)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .font(look.uiFont)
        .overlay {
            if case .connected = store.connection, store.spaces.isEmpty, store.liveTerminals.isEmpty {
                ContentUnavailableView("No terminals", systemImage: "terminal")
            }
        }
    }
}

struct TerminalRow: View {
    let terminal: CoreTerminal
    let tab: SpaceTab?
    let split: Bool

    var body: some View {
        HStack(spacing: 8) {
            ProgramIcon(terminal: terminal)
            VStack(alignment: .leading, spacing: 1) {
                Text(terminal.displayName).lineLimit(1)
                    // Done and seen, idle, or a shell at its prompt: nothing to look at, lighter.
                    .foregroundStyle(quiet ? .secondary : .primary)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            StatusMark(state: terminal.shownState)
        }
        .padding(.vertical, 2)
        .help("\(terminal.address) · \(terminal.cwd ?? "")")
    }

    private var quiet: Bool {
        switch terminal.shownState {
        case .idle: true
        case nil: terminal.isShell
        default: false
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let tab { parts.append(split ? "Tab \(tab.displayName) · split" : "Tab \(tab.displayName)") }
        if let cwd = terminal.cwd { parts.append((cwd as NSString).lastPathComponent) }
        return parts.joined(separator: " · ")
    }
}

struct ProgramIcon: View {
    let terminal: CoreTerminal

    var body: some View {
        Group {
            if let icon = ProgramIcons.icon(for: terminal) {
                Image(nsImage: icon.image)
                    .renderingMode(icon.tinted ? .template : .original)
                    .resizable().scaledToFit()
                    .frame(width: 14, height: 14)
                    .foregroundStyle(.primary)
            } else {
                Image(systemName: terminal.agentApp != nil ? "cpu" : "terminal")
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .frame(width: 22, height: 22)
        .glassEffect(.regular, in: .rect(cornerRadius: 6))
    }
}

/// Program icons from Herdr's own set (`~/.config/herdr-app/icons/<program>.svg`, the ones
/// herdr-app shows), and any the person gives a program in programs.json. Logos with their
/// own colors are drawn as they are; one-color glyphs take the text color.
enum ProgramIcons {
    struct Icon { let image: NSImage; let tinted: Bool }

    @MainActor private static var cache: [String: Icon?] = [:]

    @MainActor static func icon(for t: CoreTerminal) -> Icon? {
        // An agent's own name first (claude-code → claude-code.svg, claude.svg), then what runs.
        var names: [String] = []
        if let app = t.agentApp { names += [app, String(app.split(separator: "-").first ?? "")] }
        if let program = t.program, !t.isShell { names.append(program) }
        for name in names where !name.isEmpty {
            if let hit = cache[name] { if let hit { return hit }; continue }
            let icon = load(name)
            cache[name] = icon
            if let icon { return icon }
        }
        return nil
    }

    private static func load(_ name: String) -> Icon? {
        let home = ModHost.appHome
        let configured = (try? Data(contentsOf: home.appendingPathComponent("programs.json")))
            .flatMap { try? JSON.parse($0) }?["programs"][name]["icon"].string
        let url = configured.map { home.appendingPathComponent($0) } ?? home.appendingPathComponent("icons/\(name).svg")
        guard let image = NSImage(contentsOf: url) else { return nil }
        // Its own colors (a fill or gradient other than black/white/currentColor): a logo.
        let svg = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let colors = svg.matches(of: #/fill="(#[0-9a-fA-F]{3,8}|url\([^)]*\))"/#).map { String($0.output.1).lowercased() }
        let ownColors = colors.contains { !["#fff", "#ffffff", "#000", "#000000"].contains($0) }
        return Icon(image: image, tinted: !ownColors)
    }
}

/// blocked > done > working > idle, as in Herdr.
struct StatusMark: View {
    let state: AgentState?

    var body: some View {
        switch state {
        case .blocked:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                .symbolEffect(.pulse, options: .repeat(.continuous))
                .help("Needs you")
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Done")
        case .working:
            Image(systemName: "circle.dotted").foregroundStyle(.blue)
                .symbolEffect(.rotate, options: .repeat(.continuous))
                .help("Working")
        case .idle, nil:
            // Nothing to say: idle agents and plain shells stay quiet, as in Herdr.
            EmptyView()
        }
    }
}
