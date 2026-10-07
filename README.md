# Allman for Mac

A native macOS menu bar companion to [`allman`](https://github.com/tarkaai/allman-cli),
the local-first LinkedIn messenger CLI. Two jobs:

1. **Keep `~/.allman` live, wherever your Mac goes.** A status item shows whether
   the realtime connection is up, when the last sync ran, and a trail of what just
   synced. It restarts `allman listen` with backoff, re-syncs on wake and on
   network changes, and runs a background sync on a timer as a safety net.
2. **A full LinkedIn inbox on top of the store.** Conversation list with search and
   an unread filter, day-grouped threads with attachments and reactions, a composer
   that sends through `allman send`, and native notifications with inline Reply.

Everything on disk stays the CLI's: the app reads the store directly for speed and
shells out to the `allman` binary for every write, so rate limiting, pre-send
checks and git commits all go through the canonical path.

> Companion repos: [`allman-cli`](https://github.com/tarkaai/allman-cli) (the CLI, which this
> app embeds) and [`allman-tui`](https://github.com/tarkaai/allman-tui) (the terminal inbox).

## Requirements

- macOS 26 (Tahoe) or later — the UI uses Liquid Glass and the macOS 26 SwiftUI APIs.
- Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) to build.
- An `allman` binary to embed (`curl -fsSL https://allman.sh/install.sh | bash`), or set `ALLMAN_BIN`.

## Build & run

```bash
scripts/build.sh          # → dist/Allman.app (Release)
scripts/run.sh            # Debug build, then launch
scripts/test.sh           # unit tests
```

`scripts/build.sh` runs `xcodegen generate` and `xcodebuild`. The post-build phase copies the
`allman` binary into `Allman.app/Contents/Resources/allman`, so the app is self-contained.
Builds are ad-hoc signed; for distribution, set `CODE_SIGN_IDENTITY` and a team in `project.yml`.

## How it works

```
Sources/Allman/
  App/          AllmanApp (MenuBarExtra + Inbox window + Settings), AppModel, InboxModel, AppDelegate
  Store/        Codable models for RECORD.json / JSONL, StoreReader, FSEvents StoreWatcher, ReadState
  CLI/          AllmanBinary (resolution), AllmanProcess (spawn + NDJSON), CLIEvents (listen/sync shapes)
  Sync/         SyncEngine (listen supervisor, periodic + on-demand sync, network/sleep handling), ActivityLog
  Notifications/ UNUserNotificationCenter wrapper with Reply/Open actions
  UI/           MenuBar panel, Inbox (list, thread, composer), Settings
```

- **Reads** come straight from `$HOME/.allman` (or `ALLMAN_STORE`): every `RECORD.json` plus the
  newest JSONL line per conversation at launch, full threads on demand. An FSEvents watcher on
  the account directory reloads whatever changed — including writes from the CLI or TUI in a terminal.
- **Writes** are `allman send … --json`, `allman react … --json`, `allman sync <conv> --json`
  (history backfill on first open), and `allman login`. Every call gets `--store` and `--account`.
- **Live** state comes from a long-running `allman listen`: `connected`/`heartbeat` drive the status
  item; `message.received` posts a notification. The engine kills and restarts the subprocess when
  the network path changes, on wake from sleep, or after four minutes without a heartbeat.
- **Unread** is app-owned (Application Support/Allman/read-state.json): a thread is unread when its
  newest message is inbound, you haven't opened it since, and LinkedIn flags it unread or it arrived
  after first launch. Opening a thread marks it seen; nothing is written to the store.

## Binary resolution

Settings override → `ALLMAN_BIN` → bundled `Contents/Resources/allman` → `~/.local/bin/allman` →
`/opt/homebrew/bin`, `/usr/local/bin` → `PATH`.

## Keyboard

| Key | Action |
| --- | --- |
| `⌘I` (panel) | Open the inbox |
| `⌘R` | Sync the last day |
| `⇧⌘R` | Full re-sync of the last 7 days |
| `⌘↩` | Send the reply |
| `⇧⌘U` | Toggle unread-only |
| `⇧⌘K` | Mark all as read |
| `⇧⌘O` | Open thread on linkedin.com |

## Development notes

- `ALLMAN_SNAPSHOT_DIR=/tmp/shots open dist/Allman.app` renders the inbox window and the menu bar
  panel to PNG and quits — useful for reviewing the UI without screen-recording permission.
- Notifications need the app to run from a real `.app` bundle (they do from `dist/` or Xcode).
- Launch at Login uses `SMAppService`; macOS may ignore it for apps outside `/Applications`.

## License

MIT — see [LICENSE](./LICENSE). Read [RESPONSIBLE_USE.md](./RESPONSIBLE_USE.md).
Named, like its siblings, in tribute to [Eric Allman](https://en.wikipedia.org/wiki/Eric_Allman).
