# Contributing to gh-badge

Thanks for the interest. This file covers how to build, run, test, and extend
gh-badge. It's intentionally more technical than the README.

## Requirements

- **macOS 13 (Ventura)** or later
- A Swift toolchain. Either:
  - **Xcode** (full install), or
  - **Xcode Command Line Tools** (`xcode-select --install`) — enough to build
    and run; `test.sh` picks the right toolchain automatically.
- **`gh`** CLI, installed and logged in (`brew install gh && gh auth login`).

There are **no third-party dependencies**. SwiftPM is the build driver only.

## Build & run

```sh
./build.sh --run                 # build (release), assemble .app, launch
./build.sh --install --run       # also install to /Applications and launch
CONFIG=debug ./build.sh          # debug build instead of release
```

`build.sh` compiles with `swift build`, assembles `build/gh-badge.app`, lint-checks
the `Info.plist`, and code-signs (preferring an Apple Development identity, falling
back to ad-hoc).

## Tests

```sh
./test.sh                        # full suite
./test.sh --filter TestName      # a single test
```

40 unit tests cover the `GHBadgeCore` library — decoding, sectioning, sorting,
settings normalization, and the staleness filter. They make no network calls and
don't need `gh` on `PATH`.

## Project layout

```
Sources/
  GHBadgeCore/    library — pure logic, no SwiftUI/AppKit (unit-testable)
    PullRequest.swift     model + JSON decoding
    ProcessRunner.swift   subprocess wrapper (drains stdout/stderr, hard timeout)
    GHClient.swift        all `gh` calls (search prs, auth status, api user)
    SettingsStore.swift   persisted settings + the staleness model
    PRSectioning.swift    pure sectioning/filtering/sorting logic
    PRStore.swift         poll loop, caching, error state
  GHBadgeApp/     executable — the menu bar UI
    StatusItemController.swift  NSStatusItem: left-click popover, right-click menu
    DropdownView.swift          the three-section dropdown
    SettingsView.swift          the Settings window
    MenuBarIcon.swift           composited badge image (glyph + count)
    LoginItemController.swift   launch-at-login via SMAppService
Tests/
  GHBadgeCoreTests/
```

## Core design principle

**All GitHub access goes through the `gh` CLI.** gh-badge never talks to the
GitHub API directly and never handles tokens, refresh, or the Keychain. That
single decision is what makes the app tiny, safe, and dependency-free — and what
keeps auth "just working" because you already set up `gh`.

A few consequences worth knowing before you change things:

- `GHClient` strips `GH_TOKEN`/`GITHUB_TOKEN` (and the `*_ENTERPRISE_TOKEN`
  variants) from the child environment so a Finder launch and a terminal launch
  behave identically. `gh` always uses its own stored credential.
- `gh` discovery doesn't use `which` (a GUI app's `PATH` is too minimal). It
  probes explicit candidate paths, then falls back to `$SHELL -ilc 'command -v gh'`.
- An **empty repo whitelist means empty review sections** — that's intentional,
  not a bug, and the first two sections skip the network entirely in that state.
- The badge count is **`needsReview.count` only**, never the total across sections.
- Keep `GHBadgeCore` free of SwiftUI/AppKit. New filtering logic belongs in
  `PRSectioning`, not `PRStore`.

## Icons

Menu bar glyphs and the app icon are rendered from the Octicons SVGs in
`Support/Glyph/`. To regenerate everything after changing the source SVGs:

```sh
swift render_icons.swift
```

It writes `Support/Glyph/MenuBarGlyph*.png` (monochrome template glyphs) and
`Support/AppIcon.icns` (the full-color app icon).

## Before you open a PR

1. `./test.sh` passes.
2. `./build.sh --run` launches cleanly.
3. If you touched the dropdown or menu bar, exercise both left-click and
   right-click, and open Settings, by hand — there's no UI test coverage by
   design.
