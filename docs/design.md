# herdr-mac: a native macOS frontend for herdr-core

Status: prototype.

## Why

Herdr's window is drawn by GPUI. GPUI has no backdrop blur, no system materials and no
Liquid Glass, so Herdr can only imitate a macOS look. herdr-core (`hc`) owns every terminal
and agent and exposes them over a documented JSON-RPC API, so a second, native client can
show the same world. This repo is that client: SwiftUI for the chrome, libghostty for the
terminals. It runs beside herdr-app: same terminals, same spaces and tabs.

## Architecture

```
┌──────────────────── HerdrMac.app (SwiftUI) ─────────────────────┐
│  NavigationSplitView: glass sidebar · terminal · mod inspector   │
│     │                              │                             │
│  HerdrStore (@Observable)        TerminalView → GhosttySurfaceView│
│     │ spaces/tabs/terminals        │ pty: herdr-mac-attach <t>   │
│  HcClient (framed JSON-RPC)        │                             │
└─────┼──────────────────────────────┼─────────────────────────────┘
      │ hc connect                    │ hc connect (its own)
      └───────────► herdr-core ◄──────┘
```

### HerdrCore (library)

A Swift port of herdr-app's `src/hc.rs` (Apache-2.0):

- `HcClient` spawns `hc connect`, sends `hello {framed: true}` as one JSON line, then speaks
  frames: `u32 channel LE | u8 kind | u32 len LE | payload`. Channel 0 carries JSON-RPC.
  Kinds: DATA 0, CREDIT 1, CLOSE 2, RESIZE 3, FOCUS 4, FACTS 5, AUTOMATIC_INPUT 6.
- `HerdrStore` subscribes to events (a channel with credit, topped up per received byte),
  applies them as herdr-app does (`TerminalEvents`), and reads the `herdr-app` core document
  for Space → Tab → terminals. A terminal carrying Herdr's `herdr.space`/`herdr.tab` labels
  that no tab of the document holds shows in that tab anyway, as Herdr shows it, so tabs keep
  their space while herdr-app isn't running to adopt them. A `size` event is kept but not
  announced (it fires on every step of a window resize). Tabs started here show at once, before Herdr writes them into
  its document (`PendingTab`).
- `Navigator`: tab/space/agent next, previous and N, as Herdr numbers them; `NavMemory`
  remembers the terminal per tab and space and the order they were shown in (⌘W and a
  terminal ending go back to the previous one).
- `HerdrSettings` / `HerdrKeys`: the person's herdr-app `settings.json` and `keys.json`
  translated to Ghostty config (fonts, weights, ligatures, cell size, theme per appearance
  with Herdr's palettes; `send:` key bindings).
- `ModSource` (ES module rewriting for mods) and `UpdateFeed` (releases in a synced folder).

### Terminals: libghostty and the attach relay

- `GhosttyKit.xcframework` is built from Ghostty's latest release (v1.4.0, Zig 0.17; Zig 0.15
  can't link against the macOS 27 SDK) with `scripts/ghosttykit.sh`.
- `GhosttyRuntime` owns the one `ghostty_app_t` (wakeups, clipboard, actions) and its config:
  our defaults, then the person's Ghostty config, then their Herdr settings; reloaded live.
- `GhosttySurfaceView` (NSView + NSTextInputClient) is a reduced port of Ghostty's own
  `SurfaceView_AppKit.swift` (MIT): keyboard with IME, mouse, scroll, focus, size. While a
  program captures the mouse, ⌘ is passed as ⌘⇧ so ⌘-click still opens links.
- Ghostty's embedding API only runs a command in its own pty, so each surface runs
  `herdr-mac-attach <address>`, shipped in the app. It attaches over the framed protocol and
  shares the terminal with other windows: it attaches without taking the size (`resumed`)
  unless it's the one shown, learns keyboard focus from the surface (focus reporting on its
  own pty) and only then sends FOCUS and RESIZE, and sends what the surface writes without
  focus (replies to a program's queries) as AUTOMATIC_INPUT, which never takes the size.
  It has no detach key.
- The window keeps the last eight terminals attached (hidden ones don't draw), so switching
  back to one shows it at once.

### App

- Sidebar: spaces as sections, each tab's terminals as rows (idle ones lighter), terminals
  no tab holds under "Other terminals"; mods placed in the sidebar sit under the list.
- Keys (a per-window key monitor, before the terminal and the menus): ctrl+tab / ⌘⇧] [ tab
  next/previous, ⌘1…9 tab N, ⌘⌥] [ space, ctrl+1…9 space N, ⌘] [ agent. File menu: New Tab
  ⌘T, New Space ⌘N (folder picker), Close Tab ⌘W (asks when a program still runs).
- Light/dark follows the system unless herdr-app's `appearance` says otherwise.
- Updates: `scripts/publish.sh` puts the zip and a `version.json` (build, size, SHA-256,
  notes) in a synced folder named `herdr-mac`; the app finds it under
  `~/Library/CloudStorage/OneDrive-*`, offers newer builds in the toolbar, checks the zip and
  replaces itself.
- Packaging: SwiftPM and `scripts/bundle.sh`; no .xcodeproj. Debug builds include test hooks
  (`DebugHarness`: snapshots and scripted keys over signals); release builds don't.

## Mods

herdr-mac runs the person's Herdr mods (`~/.config/herdr-app/mods/*/main.js`) unchanged, in
JavaScriptCore, one context per placed copy:

- `ModSource` rewrites `import`/`export` into a function the host calls.
- A prelude provides "gpui-kit lite": elements record their builder calls (`div()`,
  `h_flex()`, `.px(14)`, `.bg(...)`, `.hover(...)`, `.on_click(...)`), plus `cx` (timers,
  spawn with Task, notify), `InputState`/`Input`, virtual lists and the `herdr` module. Unknown
  builder calls are recorded and ignored. `localStorage` is kept between launches (herdr-mac's
  own copy, first filled from Herdr's `data/<mod>/store.json`).
- `ModNodeView` draws the recorded tree with SwiftUI, translating GPUI's flex layout
  (stretch, `flex_1`/`min_h(0)`, justify, absolute positioning, percentage widths, scrolling).
  `theme()` gives macOS colors under Herdr's names, so mods fit the window.
- `ModHost` answers the `herdr` API from herdr-mac's own data in herdr.d.ts's shapes; shared
  state is read from herdr-app's `shared.json` (never written); `layout()` returns the
  person's Herdr layout with the mod shown.
- Places (`ModPlaces`): a sidebar slot and the inspector panel (one tab per mod). By default
  they follow the person's Herdr layout; `~/.config/herdr-app/herdr-mac.json` can set
  `sidebar`, `panel` and `hidden` (mods that are part of a person's own Herdr window).

## Direction

- Commands as the single mutation path, with herdr-app's names (`tab.new`,
  `space.select:2`), and all of `keys.json` honoured, not only `send:`.
- A layout file with native containers (sidebar, content, inspector, toolbar, splits).
- Native components for new mods (List, Label with SF Symbols, Badge, glass groups) next to
  the gpui-kit compatibility layer, so mods written for herdr-mac look native.
- Coexistence: structural edits from herdr-mac (rename, move tabs) must write herdr-app's
  core document with its version check, as herdr-app does.
