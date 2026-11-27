import HerdrCore
import SwiftUI
import TerminalKit

struct ContentView: View {
    @Environment(HerdrStore.self) private var store
    @Environment(Look.self) private var look
    @Environment(ModHost.self) private var mods
    @AppStorage("showMods") private var showMods = false
    @SceneStorage("selection") private var selection: String?
    @State private var detached: Set<String> = []
    @State private var attachGeneration = 0
    @State private var error: String?
    @State private var didApplyLaunchSelection = false
    @State private var memory = NavMemory()
    @State private var windowID = UUID()
    @State private var closing: CloseRequest?
    @State private var pickingFolder = false
    /// Terminals shown lately, most recent first: kept attached for quick switching.
    @State private var recent: [String] = []
    @State private var confirmingUpdate = false
    private let updater = Updater.shared

    struct CloseRequest {
        let tabID: String?
        let terminals: [String]
        let busy: String
        let after: String?
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 400)
        } detail: {
            detail
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .inspector(isPresented: $showMods) {
            ModPanel()
                .inspectorColumnWidth(min: 280, ideal: 380, max: 640)
        }
        .onChange(of: selection, initial: true) { _, address in
            mods.selection = address
            mods.select = { selection = $0 }
        }
        .onChange(of: look.dark, initial: true) { _, dark in mods.dark = dark }
        .alert("Update HerdrMac to \(updater.available?.version ?? "")?", isPresented: $confirmingUpdate, presenting: updater.available) { _ in
            Button("Restart Now") { updater.install() }.keyboardShortcut(.defaultAction)
            Button("Later", role: .cancel) {}
        } message: { release in
            Text(release.notes.isEmpty ? "HerdrMac restarts with the new version; your terminals keep running." : release.notes)
        }
        .alert("HerdrMac", isPresented: Binding(get: { updater.message != nil }, set: { if !$0 { updater.message = nil } })) {
            Button("OK") { updater.message = nil }
        } message: { Text(updater.message ?? "") }
        .toolbar {
            if updater.available != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Update", systemImage: updater.installing ? "hourglass" : "arrow.down.circle.fill") { confirmingUpdate = true }
                        .help("HerdrMac \(updater.available?.version ?? "") is available")
                        .disabled(updater.installing)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Mods", systemImage: "sidebar.right") { showMods.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                    .help("Show or hide the mod panel (your Herdr mods)")
            }
            ToolbarItem(placement: .primaryAction) {
                // ⌘T is the File menu's (New Tab).
                Button("New Tab", systemImage: "plus") { newShell() }
                    .help("New tab in this space (⌘T)")
            }
        }
        .alert("Something went wrong", isPresented: .constant(error != nil), presenting: error) { _ in
            Button("OK") { error = nil }
        } message: { Text($0) }
        .onChange(of: store.spaces) { selectFirstIfNeeded() }
        // The shown terminal ended (ctrl+D, exit, killed): on, as ⌘W does.
        .onChange(of: store.terminals) { selectFirstIfNeeded() }
        // Looking at a finished agent marks it seen, as in Herdr: on selecting it, when it
        // finishes while shown, and when the app comes forward with it shown.
        .onChange(of: selectedTerminal?.needsSeen) { markSelectedSeen() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in markSelectedSeen() }
        .onChange(of: selection, initial: true) { _, address in
            if let address { recent.removeAll { $0 == address }; recent.insert(address, at: 0); recent = Array(recent.prefix(8)) }
            markSelectedSeen()
            if let address { memory.note(address, in: store.navGroups) }
        }
        .focusedSceneValue(\.navigate, Navigate(window: windowID, run: navigate))
        .focusedSceneValue(\.windowActions, WindowActions(window: windowID, newTab: newShell,
                                                           newSpace: { pickingFolder = true }, closeTab: requestCloseTab))
        // New Space…: the native folder picker, starting next to the folder you're in.
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { newSpace(url.path) }
        }
        .fileDialogDefaultDirectory(selectedTerminal?.cwd.map { URL(fileURLWithPath: $0).deletingLastPathComponent() })
        .onAppear { DebugHarness.navigate = navigate }
        .background(WindowKeys(selection: selection, navigate: navigate, closeTab: requestCloseTab))
        .alert("Close this tab?", isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }),
               presenting: closing) { request in
            Button("Close Tab", role: .destructive) { close(request) }.keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text("\(request.busy) is still running here and will be stopped.")
        }
    }

    private func markSelectedSeen() {
        guard NSApp.isActive, let selection else { return }
        store.markSeen(selection)
    }

    /// ⌘W closes the tab, carefully: a tab where only shells run
    /// closes at once; one running a program (claude, vim...) asks first.
    private func requestCloseTab() {
        guard let selection else { return }
        let tab = store.spaces.flatMap(\.tabs).first { $0.terminals.contains(selection) }
        let terminals = (tab?.terminals ?? [selection]).filter { store.terminals[$0]?.isLive == true }
        let busy = terminals.compactMap { store.terminals[$0] }.filter { !$0.isShell }
        let names = Array(Set(busy.map { $0.agentApp ?? $0.program ?? $0.address })).sorted().joined(separator: ", ")
        // Back to the terminal shown before this one; never having left it, the next tab in
        // the space, else the previous, else another space.
        let inTab = Set(terminals)
        let after = memory.previous(excluding: inTab) { store.terminals[$0]?.isLive == true }
            ?? [Navigation.tabNext, .tabPrev, .spaceNext].lazy.compactMap {
                Navigator.target($0, from: selection, groups: store.navGroups, agents: [], memory: memory)
            }.first { !inTab.contains($0) }
        let request = CloseRequest(tabID: tab?.id, terminals: terminals, busy: names, after: after)
        if busy.isEmpty { close(request) } else { closing = request }
    }

    private func close(_ request: CloseRequest) {
        closing = nil
        if let after = request.after { selection = after }
        Task {
            do { try await store.closeTab(id: request.tabID, terminals: request.terminals) }
            catch { self.error = "Couldn't close the tab: \(error)" }
        }
    }

    /// Runs a switching command (tab/space/agent next, previous, N) from the Go menu.
    private func navigate(_ nav: Navigation) {
        if let target = Navigator.target(nav, from: selection, groups: store.navGroups,
                                         agents: store.agentAddresses, memory: memory) {
            selection = target
        }
    }

    @ViewBuilder private var detail: some View {
        switch store.connection {
        case .failed(let message):
            ContentUnavailableView {
                Label("herdr-core is not reachable", systemImage: "bolt.horizontal.circle")
            } description: { Text(message) } actions: {
                Button("Try Again") { store.start() }
            }
        case .connecting:
            ProgressView("Connecting to herdr-core…")
        case .connected:
            if let address = selection, let terminal = store.terminals[address], terminal.isLive, let hc = store.hcPath {
                if detached.contains(address) {
                    ContentUnavailableView {
                        Label("Detached from \(terminal.displayName)", systemImage: "rectangle.portrait.and.arrow.right")
                    } description: {
                        Text("The terminal keeps running in herdr-core.")
                    } actions: {
                        Button("Reattach") { detached.remove(address); attachGeneration += 1 }
                            .buttonStyle(.glassProminent)
                    }
                } else {
                    // The last few terminals stay attached, hidden: switching back shows them at
                    // once, with no new process, connection or history to replay.
                    ZStack {
                        ForEach(kept(address), id: \.self) { kept in
                            TerminalView(address: kept, hcPath: hc, observe: Self.watchOnly(kept), active: kept == address) {
                                detached.insert(kept)
                                recent.removeAll { $0 == kept }
                            }
                            .id("\(kept)#\(attachGeneration)")
                            .opacity(kept == address ? 1 : 0)
                            .allowsHitTesting(kept == address)
                        }
                    }
                    .ignoresSafeArea(.container, edges: .bottom)
                }
            } else {
                ContentUnavailableView("No terminal selected", systemImage: "terminal",
                                       description: Text("Pick one in the sidebar, or press ⌘T for a new shell."))
            }
        }
    }

    /// `HERDR_MAC_ONLY_TYPE_IN=t56,t57`: every other terminal is shown watch-only, so
    /// automated tests can never type into (or resize) the person's own sessions.
    static func watchOnly(_ address: String) -> Bool {
        #if DEBUG
        guard let only = ProcessInfo.processInfo.environment["HERDR_MAC_ONLY_TYPE_IN"] else { return false }
        return !only.split(separator: ",").contains(Substring(address))
        #else
        return false
        #endif
    }

    private var selectedTerminal: CoreTerminal? { selection.flatMap { store.terminals[$0] } }

    private var selectedSpace: Space? {
        guard let selection else { return store.spaces.first }
        return store.spaces.first { $0.tabs.contains { $0.terminals.contains(selection) } } ?? store.spaces.first
    }

    private var title: String { selectedTerminal?.displayName ?? "Herdr" }

    private var subtitle: String {
        guard let t = selectedTerminal else { return "" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cwd = t.cwd.map { $0.hasPrefix(home) ? "~" + $0.dropFirst(home.count) : $0 } ?? ""
        return [t.agentApp ?? t.program, cwd].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func selectFirstIfNeeded() {
        #if DEBUG
        // `--select <address>` on launch picks a terminal (for testing).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--select"), i + 1 < args.count, store.terminals[args[i + 1]] != nil, selection != args[i + 1],
           !didApplyLaunchSelection {
            didApplyLaunchSelection = true
            selection = args[i + 1]
            return
        }
        #endif
        // Keep a live selection, and one just started here (its created event may not have
        // arrived when Herdr's document changes): ⌘T used to jump back to the first terminal.
        if let selection, store.terminals[selection]?.isLive == true || store.isPending(selection) { return }
        // Gone (it ended, or it was closed elsewhere): back to the terminal shown before it,
        // as ⌘W does; else the first one.
        let gone = selection
        // Starting up: terminals come before Herdr's document; pick once its tabs are known.
        if gone == nil && store.spaces.isEmpty { return }
        if let gone { detached.remove(gone) }
        selection = memory.previous(excluding: Set([gone].compactMap { $0 })) { store.terminals[$0]?.isLive == true }
            ?? store.spaces.first?.tabs.first?.terminals.first { store.terminals[$0]?.isLive == true }
            ?? store.liveTerminals.first?.address
    }

    /// The shown terminal and up to seven shown before it that are still live and attached.
    private func kept(_ shown: String) -> [String] {
        let others = recent.filter { $0 != shown && store.terminals[$0]?.isLive == true && !detached.contains($0) }
        return ([shown] + others.prefix(7)).sorted() // stable order: views keep their place in the stack
    }

    private func newSpace(_ folder: String) {
        Task {
            do { selection = try await store.newSpace(folder: folder) }
            catch { self.error = "Couldn't start the space: \(error)" }
        }
    }

    private func newShell() {
        let space = selectedSpace
        Task {
            do { selection = try await store.newShell(in: space) }
            catch { self.error = "\(error)" }
        }
    }
}
