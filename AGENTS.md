# Snaplane — agent notes

Native AppKit menu-bar app. Hold Shift, drag a window, drop it in a lane.

**Not FancyZones.** That name is Microsoft PowerToys. Do not rename this app back.

## Layout

- `Sources/` — the app. `Snapper.swift`, `Overlay.swift`, `Editor.swift` are the core.
- `Resources/Info.plist` — bundle id `com.astucore.snaplane`.
- `scripts/build.sh` — compile, sign with a *local* identity, install to `/Applications/Snaplane.app`.
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

## Autonomous maintenance

When Grok Bot is asked to maintain this repo:

- **New issue:** label `bug` / `enhancement` / `question`. Reply once. Close obvious duplicates and spam.
- **New or updated PR:** wait for CI or compile. Review for signing-key leaks, hardcoded `/Users/mac` paths, and snap/editor regressions. Comment; do not merge.
- **CI red:** fix compile errors on a branch and push. Do not rewrite `main` history.
- Notify the owner only for security reports, permission-model changes, or notarized releases.

Owner: `@bcovington`. Org: [Astucore-ai](https://github.com/Astucore-ai).
