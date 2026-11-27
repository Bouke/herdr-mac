# herdr-mac

A native macOS frontend for [herdr-core](https://github.com/herdrdev/herdr): SwiftUI with
Liquid Glass for the window, libghostty for the terminals. It shows the same spaces, tabs
and terminals as the Herdr app and runs beside it; both are clients of one herdr-core.

A prototype, and not an official Herdr project.

How it works: [docs/design.md](docs/design.md).

## Build and run

Needs macOS 26+ on Apple Silicon, Xcode with its Metal Toolchain, Zig 0.17 and herdr-core.

```sh
cp scripts/local.env.example scripts/local.env   # optional: paths on this machine
scripts/ghosttykit.sh        # once: builds Vendor/GhosttyKit.xcframework from Ghostty v1.4.0
scripts/bundle.sh            # builds build/HerdrMac.app (release; `debug` adds test hooks)
open build/HerdrMac.app
```

## Using it

- The sidebar lists Herdr's spaces and tabs with each agent's status; click one to work in
  it. Terminals stay alive in herdr-core when you switch or quit.
- ⌘T new tab, ⌘N new space (pick a folder), ⌘W close tab (asks while a program runs).
- ctrl+tab / ⌘⇧] ⌘⇧[ next/previous tab, ⌘1…9 tab N, ⌘⌥] ⌘⌥[ next/previous space,
  ctrl+1…9 space N, ⌘] ⌘[ next/previous agent. Closing or ending a tab goes back to the
  one you came from.
- Looks and fonts come from herdr-app's `~/.config/herdr-app/settings.json` (font, size,
  weights, ligatures, line height, theme for light and dark, …) and its `keys.json` `send:`
  bindings, live; then your Ghostty config for anything else about the terminal.
- Your Herdr mods run too: in the sidebar or the panel on the right (⌘⌥I), placed as in your
  Herdr layout. `~/.config/herdr-app/herdr-mac.json` can change that:

  ```json
  { "sidebar": ["usage"], "panel": ["tasks", "inbox"], "hidden": ["my-sidebar"] }
  ```

## Releases

`scripts/publish.sh "notes"` puts a build and its `version.json` in a synced folder
(`HERDR_MAC_RELEASES`, e.g. a shared OneDrive folder named `herdr-mac`). Copies of the app
on Macs that sync that folder offer the new build in their toolbar and install it
themselves.

## Develop

```sh
swift test                                # protocol, model, navigation, settings tests
swift run herdr-mac-probe 5               # prints spaces/tabs/terminals and live changes
scripts/bundle.sh debug                   # a build with test hooks (see DebugHarness.swift)
```

## License

Apache-2.0, see [LICENSE](LICENSE). Includes work from Herdr (Apache-2.0) and Ghostty (MIT);
see [NOTICE](NOTICE).
