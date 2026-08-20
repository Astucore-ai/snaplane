# Snaplane — agent notes

Native AppKit menu-bar app. Hold Shift, drag a window, drop it in a lane.

**Not FancyZones.** That name is Microsoft PowerToys. Do not rename this app back.

## Layout

- `Sources/` — the app. `Snapper.swift`, `Overlay.swift`, `Editor.swift` are the core.
- `Resources/Info.plist` — bundle id `com.astucore.snaplane`.
- `scripts/build.sh` — compile, sign with a *local* identity, install to `/Applications/Snaplane.app`, rewrite and bootstrap KeepAlive (`keep-alive.sh`). Never leave the app off after a build.
- `scripts/compile-check.sh` — compile only. This is what CI runs.
- `scripts/ensure-identity.sh` — creates a gitignored identity in `signing/`.
- `scripts/debug-canvas.swift` — launches the app with `--debug-canvas` for editor debugging.
- `signing/` — **never commit**. `.gitignore` already covers it.

## Rules

1. Do not commit `signing/`, `*.p12`, `*.cer`, `*.keychain-db`, or logs.
2. Do not merge PRs. Leave them for a human.
3. Do not force-push `main` unless GitHub is missing the app. Prefer `--force-with-lease`.
4. Public clone + `./scripts/build.sh` must work on Apple silicon macOS 13+.
5. Accessibility is bound to the code signature. A new identity breaks permissions until toggled off/on.
6. Canonical remote is `https://github.com/Astucore-ai/snaplane`.
7. KeepAlive must stay loaded in the current GUI session (`launchctl print gui/$(id -u)/com.astucore.snaplane`). The process parent should be launchd. Overlay/editor windows must set `animationBehavior = .none` and not deallocate on the same turn as `orderOut`.
8. Prefer a **Developer ID Application** identity when one exists (`scripts/codesign-app.sh`). Do not mint a new local cert if a Developer ID is available — that resets Accessibility.

## Autonomous maintenance

When Grok Bot is asked to maintain this repo:

- **New issue:** label `bug` / `enhancement` / `question`. Reply once. Close obvious duplicates and spam.
- **New or updated PR:** wait for CI or compile. Review for signing-key leaks, hardcoded `/Users/mac` paths, and snap/editor regressions. Comment; do not merge.
- **CI red:** fix compile errors on a branch and push. Do not rewrite `main` history.
- Notify the owner only for security reports, permission-model changes, or notarized releases.

Org: [Astucore-ai](https://github.com/Astucore-ai).
