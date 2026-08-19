# Snaplane

Custom window zones for macOS. Hold Shift, drag a window, drop it in a lane.

Snaplane is an Astucore app ([source](https://github.com/bcovington/snaplane)). It is inspired by the zone-snapping workflow of Microsoft PowerToys on Windows, but it is original software with its own name, code, and identity.

## Why not “FancyZones”?

**FancyZones** is the name of a Microsoft PowerToys feature. PowerToys itself is open source (MIT), but the product name is Microsoft’s. Shipping an independent Mac app under that name would be confusing and a trademark risk. **Snaplane** is the Astucore name.

## Install

Requires macOS 13+ on Apple silicon (the checked-in build script targets `arm64`).

```bash
git clone https://github.com/bcovington/snaplane.git
cd snaplane
./scripts/build.sh
```

That compiles a signed `Snaplane.app`, installs it to `/Applications`, and registers a LaunchAgent so it starts at login and restarts if it quits.

Then enable **Snaplane** in **System Settings → Privacy & Security → Accessibility**. macOS binds that permission to the app’s signature — toggle it off and on if a rebuild stops snapping.

## Use

| Action | How |
| --- | --- |
| Snap with the mouse | Hold **Shift** and drag a window onto a highlighted zone |
| Snap two adjacent zones | Hover the shared edge while dragging |
| Add more zones | Hold **Control** while dragging |
| Snap focused window | **⌃⌥ ← → ↑ ↓** |
| Expand across zones | **⌃⌥⌘ arrows** |
| Open layout editor | **⌃⌥⇧`** |
| Settings | **⌃⌥⇧,** |
| Switch layout | **⌃⌥⌘ 1–5** |
| Cycle windows in a zone | **⌃⌥ Page Up / Page Down** |

The app lives in the menu bar. **Quit** is restarted by launchd on purpose. Use **Stop until next login** to actually unload it.

Turn off Rectangle, MacsyZones, or similar tools while Snaplane is running so their shortcuts do not collide.

## Layouts

Defaults, each assignable to a display:

1. Columns
2. Four Columns
3. Focus
4. Rows
5. Grid
6. Priority Grid

Create a **canvas** layout (free-floating, overlapping zones) or a **grid** layout from the editor. Assign **⌃⌥⌘ 0–9** as a quick-switch hotkey per layout.

Config lives at `~/Library/Application Support/Snaplane/config.json`.

## Persistence

`~/Library/LaunchAgents/com.astucore.snaplane.plist`

- `RunAtLoad` — starts at login
- `KeepAlive` — relaunches if the process dies
- `AssociatedBundleIdentifiers` — so Accessibility applies to the LaunchAgent job

## Development

```text
Sources/     AppKit app (menu bar, overlay, editor, settings)
Resources/   Info.plist, app icon
scripts/     build.sh, ensure-identity.sh, smoke-test.swift
```

`./scripts/build.sh [icon.png]` creates a local code-signing identity in `signing/` (gitignored) so Accessibility survives rebuilds.

```bash
swift scripts/smoke-test.swift
```

## License

MIT © Astucore
