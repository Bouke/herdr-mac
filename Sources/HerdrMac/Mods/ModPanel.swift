import HerdrCore
import SwiftUI

/// One mod in one place of the window, with its own running copy (as Herdr runs one copy
/// per block). Re-renders when what mods read changes, as Herdr does.
struct ModSlot: View {
    let mod: String
    let place: ModPlaces.Place
    @Environment(HerdrStore.self) private var store
    @Environment(Look.self) private var look
    @Environment(ModHost.self) private var host
    @State private var instance: ModInstance?
    @AppStorage("modPanel.showLog") private var showLog = false

    var body: some View {
        Group {
            if let instance {
                if let error = instance.error {
                    ScrollView {
                        Text("\(mod): \(error)").font(.system(.caption, design: .monospaced)).foregroundStyle(.red)
                            .textSelection(.enabled).padding().frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: place == .sidebar ? 120 : .infinity)
                } else if let tree = instance.tree {
                    let view = ModNodeView(node: tree, inherited: ModText(), theme: ModTheme(dark: look.dark),
                                           stretch: true, parentRow: false, click: { instance.click($0) },
                                           input: { instance.input($0, $1, $2) })
                    if place == .sidebar {
                        // As tall as its content. A Herdr mod asks for its block's height with
                        // layout.resize, worked out from Herdr's row heights; rows come out a
                        // little taller here, so that height would cut it off or overlap.
                        view.fixedSize(horizontal: false, vertical: true).clipped()
                    } else {
                        // Never taller than the panel, whatever the mod draws.
                        view.frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading).clipped()
                    }
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
                if showLog && place == .panel {
                    Divider()
                    ScrollView {
                        Text(instance.log.suffix(50).joined(separator: "\n")).font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                }
            } else {
                // Something must be here before the mod runs: an empty Group never appears,
                // so onAppear (which starts the mod) would never fire.
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(8)
            }
        }
        .onAppear(perform: restart)
        .onDisappear { instance?.close(); instance = nil }
        .onChange(of: mod) { restart() }
        // Coalesced: one render per run-loop turn, never inside SwiftUI's update.
        .onChange(of: store.terminals) { instance?.queueRender() }
        .onChange(of: store.spaces) { instance?.queueRender() }
        .onChange(of: host.selection) { instance?.queueRender() }
        .onChange(of: host.version) { instance?.queueRender() }
        .onChange(of: look.dark) { instance?.queueRender() }
    }

    func restart() {
        instance?.close()
        host.store = store
        host.dark = look.dark
        instance = ModInstance(name: mod, host: host)
    }
}

/// The inspector: the mods placed in the panel, one tab each (Herdr's panel-body stack).
struct ModPanel: View {
    @Environment(ModPlaces.self) private var places
    @AppStorage("modPanel.mod") private var selected = ""
    @AppStorage("modPanel.showLog") private var showLog = false

    var body: some View {
        let mods = places.panel
        let current = mods.contains(selected) ? selected : mods.first
        VStack(alignment: .leading, spacing: 0) {
            if mods.count > 1 {
                Picker("Mod", selection: Binding(get: { current ?? "" }, set: { selected = $0 })) {
                    ForEach(mods, id: \.self) { Text(ModHost.title($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            if let current {
                ModSlot(mod: current, place: .panel).id(current)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ContentUnavailableView("No mods in the panel", systemImage: "puzzlepiece.extension",
                                       description: Text("Choose “Show in Panel” for a mod in the menu above."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { ModPlacesMenu(showLog: $showLog) }
        }
    }
}

/// Where each mod shows: Sidebar (bottom), Panel or hidden. Writes herdr-mac.json.
struct ModPlacesMenu: View {
    @Environment(ModPlaces.self) private var places
    @Binding var showLog: Bool

    var body: some View {
        Menu {
            Section(places.fromFile ? "Places (herdr-mac.json)" : "Places (from your Herdr layout)") {
                ForEach(ModHost.mods().filter { !places.isWindowPart($0) }, id: \.self) { mod in
                    Picker(ModHost.title(mod), selection: Binding(get: { places.place(of: mod)?.rawValue ?? "hidden" },
                                                                  set: { places.move(mod, to: ModPlaces.Place(rawValue: $0)) })) {
                        Text("Sidebar").tag("sidebar")
                        Text("Panel").tag("panel")
                        Text("Hidden").tag("hidden")
                    }
                }
            }
            Divider()
            Toggle("Show Mod Log", isOn: $showLog)
        } label: {
            Label("Mods", systemImage: "puzzlepiece.extension")
        }
        .help("Where your Herdr mods show")
    }
}

/// The mods placed in the sidebar, stacked at its bottom (Herdr's sidebar blocks).
struct SidebarMods: View {
    @Environment(ModPlaces.self) private var places

    var body: some View {
        if !places.sidebar.isEmpty {
            VStack(spacing: 0) {
                ForEach(places.sidebar, id: \.self) { ModSlot(mod: $0, place: .sidebar) }
            }
        }
    }
}
