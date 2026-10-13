# Developing Allman for Mac

How the app is built, how it talks to the CLI, and how to run it without touching LinkedIn.
For what the app does, see [GUIDE.md](./GUIDE.md). For the window's layout rules and how
each is enforced, see [UI-RULES.md](./UI-RULES.md).

## Requirements

- macOS 26 (Tahoe) or later: the UI uses Liquid Glass and the macOS 26 SwiftUI APIs.
- Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- An `allman` binary to embed, **0.5 or newer** (it needs `read`, `people`, `whoami` and
  `send --reply-to`): `curl -fsSL https://allman.sh/install.sh | bash`, or build
  `allman-cli` and set `ALLMAN_BIN`.

## Build, run, test

```bash
scripts/build.sh          # → dist/Allman.app (Release)
scripts/run.sh            # Debug build, then launch
scripts/test.sh           # rule lint + unit tests + the mock-data UI run
```

`scripts/build.sh` runs `xcodegen generate` and `xcodebuild`. The post-build phase copies the
`allman` binary into `Allman.app/Contents/Resources/allman`, so the app is self-contained.
Builds are ad-hoc signed; for distribution, set `CODE_SIGN_IDENTITY` and a team in `project.yml`.

`scripts/test.sh` runs `scripts/check-rules.sh` (static checks over the sources), the unit tests,
and a mock-data UI run: the suite launches a second copy of the app on a synthetic store with
the fake CLI, the app drives its own window (clicks, key presses, scroll views) and reports a
verdict per rule, with a screenshot of each state. The run never takes focus: the window shows
once, behind whatever you are doing. The test harness contains no real people or real
conversations; everything comes from `Tests/AllmanTests/MockStore.swift` and the fixtures.

## Release

```bash
scripts/release.sh                      # tag v$MARKETING_VERSION, embed latest stable allman-cli
scripts/release.sh --cli-version v0.4.0 # pin the embedded CLI
scripts/release.sh --suffix alpha.1     # prerelease
scripts/release.sh --dry-run            # build + zip only
```

Bump `MARKETING_VERSION` in `project.yml` first. The script runs the same gate as
`scripts/test.sh`, downloads the CLI's `darwin-arm64` release binary (checksum-verified), builds
Release/arm64, checks the embedded CLI reports the expected version, zips
`dist/Allman-<version>-arm64.zip`, tags `v<version>` and publishes a GitHub release. Tags
without a suffix are stable.

## Running without LinkedIn

```bash
scripts/harness.sh                                   # app on a throwaway copy of ~/.allman + fake CLI
scripts/harness.sh ALLMAN_SNAPSHOT_DIR=/tmp/shots ALLMAN_SNAPSHOT_CONV=Jamie \
    ALLMAN_SNAPSHOT_SEND="hello" FAKE_SEND_DELAY=3   # a fake send, captured every ~100 ms
```

`scripts/fake-allman.sh` stands in for the CLI: `send` appends to the thread's JSONL after a
delay (`FAKE_SEND_DELAY` for when the command returns, `FAKE_SEND_WRITE_DELAY` for when the
message lands in the store, `FAKE_SEND_FAIL=1` to fail; `send a,b` creates a group thread),
and `enrich`, `connections` and `connect` are simulated against the store copy. Sends,
failures and network jobs can be exercised and screenshotted without touching LinkedIn or
the real store. The Network page says when it is running against the fake CLI.

### Snapshot mode

`open dist/Allman.app --env ALLMAN_SNAPSHOT_DIR=/tmp/shots` renders the inbox window (plus the
swipe-reveal state and unread filter), the menu bar panel, the sign-in state and Settings to
PNG and quits. Add `ALLMAN_SNAPSHOT_CONV=<name>` to pick the thread,
`ALLMAN_SNAPSHOT_COMPOSE=<query>` to capture the compose state,
`ALLMAN_SNAPSHOT_SEARCH=<query>` for full-text search, `ALLMAN_SNAPSHOT_ORGANIZE=1` for labels,
notes and reminders, `ALLMAN_SNAPSHOT_SNIPPETS=1` for the snippet picker,
`ALLMAN_SNAPSHOT_NETWORK=1` for the Network page, `ALLMAN_SNAPSHOT_INSIGHTS=1` for Insights,
and `ALLMAN_SNAPSHOT_PINS=a,b,c` to pin threads for the capture (restored afterwards).

## How it works

```
Sources/Allman/
  App/          AllmanApp (MenuBarExtra + window), AppModel, InboxModel, AppDelegate,
                UIProbe (AppKit-backed frame probes), UIRuleChecks (the mock-data UI run)
  Store/        Codable models for RECORD.json / JSONL, StoreReader, FSEvents StoreWatcher,
                ReadState, Organizer (labels, notes, snooze), Insights
  CLI/          AllmanBinary (resolution), AllmanProcess (spawn + NDJSON), CLIEvents
  Sync/         SyncEngine (listen supervisor, periodic + on-demand sync, network/sleep), ActivityLog
  Notifications/ UNUserNotificationCenter wrapper with Reply/Open actions
  UI/           Inbox (window chrome, list, thread, composer, contact panel, insights),
                Network, Settings, MenuBar panel, Shared (IconButton, avatars)
```

Everything on disk stays the CLI's: the app reads the store directly for speed and shells out
to the `allman` binary for every write, so rate limiting, pre-send checks and git commits all
go through the canonical path. The app never calls LinkedIn itself.

- **Reads** come straight from `$HOME/.allman` (or `ALLMAN_STORE`): every `RECORD.json` plus
  the newest JSONL line per conversation at launch, full threads on demand. An FSEvents watcher
  on the account directory reloads whatever changed, including writes from the CLI or TUI in a
  terminal.
- **Media** (images, files, voice notes, video) is downloaded by `allman media <conv> --json`
  when a thread opens and rendered from `{conv}/media/` on disk. The app never fetches
  LinkedIn's CDN itself.
- **Writes** are `allman send … --json` (with `--reply-to` for quoted replies, `a,b` targets
  for groups), `allman react … --json`, `allman read <target> --json` (when you open a thread,
  so linkedin.com matches), `allman sync <conv> --json` (history backfill on first open, and a
  small re-pull so reactions changed elsewhere show up), and `allman login`. Compose search
  uses `allman people <query> --json`. Every call gets `--store` and `--account`.
- **Live** state comes from a long-running `allman listen`: `connected`/`heartbeat` drive the
  status item; `message.received` posts a notification. The engine kills and restarts the
  subprocess when the network path changes, on wake from sleep, or after four minutes without
  a heartbeat.
- **App-owned state** (read watermarks, pins, labels, notes, snoozes, reminders, snippets)
  lives under `~/Library/Application Support/Allman/` (`ALLMAN_APPSUPPORT` overrides), never
  in the store.

### Binary resolution

Settings override → `ALLMAN_BIN` → bundled `Contents/Resources/allman` → `~/.local/bin/allman`
→ `/opt/homebrew/bin`, `/usr/local/bin` → `PATH`.

### Notes

- Notifications need the app to run from a real `.app` bundle (they do from `dist/` or Xcode).
- Launch at Login uses `SMAppService`; macOS may ignore it for apps outside `/Applications`.
- The window draws its own chrome (no system toolbar) so the sidebar can run full height and
  the top bar can hold the experience switcher; see [UI-RULES.md](./UI-RULES.md) for why.
