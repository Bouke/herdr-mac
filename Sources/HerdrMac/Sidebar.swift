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
            list
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
                        TerminalRow(terminal: t, tab: nil, split: false).tag(t.address)
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
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .frame(width: 22, height: 22)
            .glassEffect(.regular.tint(tint.opacity(0.35)), in: .rect(cornerRadius: 6))
    }

    private var symbol: String {
        switch terminal.agentApp ?? terminal.program ?? "" {
        case let a where a.contains("claude"): "sparkle"
        case let a where a.contains("codex"): "chevron.left.forwardslash.chevron.right"
        case "nvim", "vim", "hx": "pencil.line"
        case "lazygit", "git": "arrow.triangle.branch"
        default: terminal.agentApp != nil ? "cpu" : "terminal"
        }
    }

    private var tint: Color {
        switch terminal.agentApp ?? "" {
        case let a where a.contains("claude"): .orange
        case let a where a.contains("codex"): .teal
        case "": .gray
        default: .indigo
        }
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
