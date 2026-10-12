# Allman for Mac

A native macOS menu bar companion to [`allman`](https://github.com/tarkaai/allman-cli),
the local-first LinkedIn messenger CLI. Two jobs:

1. **Keep `~/.allman` live, wherever your Mac goes.** A status item shows whether
   the realtime connection is up, when the last sync ran, and a trail of what just
   synced. It restarts `allman listen` with backoff, re-syncs on wake and on
   network changes, and runs a background sync on a timer as a safety net.
2. **A full LinkedIn inbox on top of the store.** An iMessage-style inbox: searchable
   list with filters and Messages-style pinned favorites, blue/gray threads with
   swipe-to-reveal times, link previews, LinkedIn-style reactions and reply quoting,
   a compose sheet that finds people in your conversations, your connections, or on
   LinkedIn (`allman people`), native notifications with inline Reply, and read state
   mirrored to linkedin.com (`allman read`).
3. **An organized, keyboard-first inbox.** Full-text search across every stored
   message; labels that act as split inboxes (a thread can be in several); private
   notes per contact; snooze and reminders; archive; saved-reply snippets with
   `{firstName}`-style placeholders; a contact inspector fed by `allman enrich`;
   and a Network window for your connections, enrichment and connection requests.

## Layout

One window, four experiences (`⌘1`–`⌘4`): **Messenger**, **Network**, **Insights**,
**Settings**. The switcher sits on the toolbar row beside the sidebar toggle (and moves to
the detail's leading edge when the sidebar is collapsed). Every experience has the same
shape: the sidebar carries that experience's navigation, with the signed-in account at the bottom
(the chevron collapses account actions: switch, sync, sync older history, add, sign out,
settings); the page's header sits on the toolbar row, left-aligned, with the page's actions
on the right. There is no separate Settings window.

The messenger sidebar: the inbox bar — every label is an inbox, shown as icon chips with
*All* and *Unread*, plus the filter menu, new label, the selected thread's actions and New
Message; search; pins for the current inbox; the list. Hovering a row reveals pin /
labels / snooze / note / archive (the popovers open on the row), and trackpad swipes work
Mail-style: right for read / pin, left for archive / snooze / label. **New Message** (`⌘N`
or the compose button) turns the search field into a people search — your conversations,
your connections, LinkedIn via `allman people`, or a pasted profile link — and picking
someone opens a draft in the detail pane. Each row's avatar carries the messenger's mark. The thread header is about the person: name with the
messenger's mark (LinkedIn today — Allman is built for more than one), their brief and
their location on separate rows; the `i` at the right opens the contact details inspector.

## Inbox organization

All of this is app-owned, per account, under `~/Library/Application Support/Allman/`
(never in the store, so the CLI's git history stays clean):

- **Search** ranks by relevance: an exact or prefix match on the name first, then a
  word prefix or initials, then handle / headline / company, then a substring of the
  last message. From three characters it also scans every stored message body (what
  `allman grep` does) and lists hits under *Messages*; opening a hit jumps the thread
  to that message.
- **Labels** tag a thread with any number of labels (`L` or `⇧⌘L`). Each label is its
  own inbox, with an SF Symbol icon: the chips in the inbox bar switch between them.
  Rename, change the icon or delete from a chip's context menu.
- **Notes** keep context on a person (`N` or `⇧⌘N`), in the inspector or a popover.
- **Snooze** (`H` or `⇧⌘H`) hides a thread until a time — it comes back early if
  they write. **Remind** keeps it in place and pings you at the time. Due reminders
  post a notification, show a banner in the thread and a bell in the list; the clock
  chip / *Snoozed & reminders* view lists them.
- **Archive** (`E` or `⌘E`) clears a thread; a new message brings it back. Archive and
  snooze show a toast with Undo (`⇧⌘Z`).
- **Snippets** (`⇧⌘S`, the quote button, or a lone `/` in an empty field) insert saved
  replies with `{firstName} {lastName} {name} {slug} {company} {title} {me}` filled in.
  Manage them in Settings → Snippets. They share allman-tui's template format and are
  seeded from `~/.config/allman-tui/templates.json` on first launch.
- **Voice notes** are transcribed on this Mac with the Speech framework (no network) the
  first time they're shown, and the transcript appears under the player. Toggle in
  Settings → Behavior. **Record one** with the mic in an empty message field (Return to
  stop, listen back, Return to send): the m4a goes out through `allman send --audio`
  (allman-cli PR #46), never from Swift, and lands beside the thread under `media/`.
- **Pictures are cached** (profile photos, link previews) under `~/Library/Caches/Allman`
  for 30 days, keyed on the CDN path so refreshed tokens still hit; see Settings → Store.
- **Insights** (`⇧⌘I`) show sent/received volume, reply rate and median reply time,
  threads waiting on you, messages per week and your most active contacts.
- **Export** (File menu) writes every conversation with labels and notes as CSV for a
  spreadsheet or CRM, or the open thread as Markdown.
- **Contact details** (`I` or `⌥⌘I`) show pronouns, degree, role, location, about,
  experience, education and skills from the connections store once `allman enrich`
  has run; *Fetch profile details* runs `allman enrich <slug> --deep` for one person.

## Network

`⌘2` shows your stored 1st-degree network as a sortable,
searchable table — name, title, company, location, connected date, enrichment —
with *Message*, *Open profile* and *Fetch details* per row. The toolbar drives the
CLI's network jobs with live progress: **Pull Connections** (`allman connections`),
**Enrich** up to N profiles (`allman enrich --json --limit N [--deep]`) and
**Connect…** (`allman connect <slug> [--note …]`, with the 300-character cap, the
CLI's duplicate / already-invited checks and its daily quota). *Invitations sent*
lists what `invitations/` records. The compose sheet offers *Connect* on 2nd/3rd
degree LinkedIn results.

Everything on disk stays the CLI's: the app reads the store directly for speed and
shells out to the `allman` binary for every write, so rate limiting, pre-send
checks and git commits all go through the canonical path.

> Companion repos: [`allman-cli`](https://github.com/tarkaai/allman-cli) (the CLI, which this
> app embeds) and [`allman-tui`](https://github.com/tarkaai/allman-tui) (the terminal inbox).

## Install

Grab `Allman-<version>-arm64.zip` from the [releases page](https://github.com/tarkaai/allman-mac/releases),
unzip, move `Allman.app` to /Applications and launch it — it lives in the menu bar. Builds are
ad-hoc signed and not notarized, so on first launch right-click **Allman.app → Open**. Requires
macOS 26 on Apple Silicon.

## Requirements

- macOS 26 (Tahoe) or later — the UI uses Liquid Glass and the macOS 26 SwiftUI APIs.
- Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) to build.
- An `allman` binary to embed, **0.5 or newer** (it needs `read`, `people`, `whoami` and `send --reply-to`):
  `curl -fsSL https://allman.sh/install.sh | bash`, or build `allman-cli` and set `ALLMAN_BIN`.

## Build & run

```bash
scripts/build.sh          # → dist/Allman.app (Release)
scripts/run.sh            # Debug build, then launch
scripts/test.sh           # unit tests
```

`scripts/build.sh` runs `xcodegen generate` and `xcodebuild`. The post-build phase copies the
`allman` binary into `Allman.app/Contents/Resources/allman`, so the app is self-contained.
Builds are ad-hoc signed; for distribution, set `CODE_SIGN_IDENTITY` and a team in `project.yml`.

## Release

```bash
scripts/release.sh                      # tag v$MARKETING_VERSION, embed latest stable allman-cli
scripts/release.sh --cli-version v0.4.0 # pin the embedded CLI
scripts/release.sh --suffix alpha.1     # prerelease
scripts/release.sh --dry-run            # build + zip only
```

Bump `MARKETING_VERSION` in `project.yml` first. The script runs the unit tests, downloads the
CLI's `darwin-arm64` release binary (checksum-verified), builds Release/arm64, checks the embedded
CLI reports the expected version, zips `dist/Allman-<version>-arm64.zip`, tags `v<version>` and
publishes a GitHub release. Tags without a suffix are stable.

## Menu bar and accounts

- **Click** the menu bar icon to open the inbox; **right-click** (or control-click) for the status
  panel: who is signed in, live/sync state, recent activity, Launch at Login, Settings, Quit.
- The panel and the sidebar show your own LinkedIn profile (photo, name, headline). The app runs
  `allman whoami --refresh` once per launch so `AUTH.json` carries them.
- **Several accounts** can be signed in at once: every account keeps its own `allman listen` +
  periodic sync and sends notifications; the inbox window shows one at a time. Switch from the
  avatar in the sidebar toolbar, the panel header, or the Inbox menu; add one with **Add Account…**
  (runs `allman login` for a new profile; *Options…* adds `--proxy host:port[:user:pass]` or
  `--no-salesnav`) and sign out from Settings → Accounts (`allman logout`).
  Read watermarks and pins are kept per account.

## Local harness (no LinkedIn)

```bash
scripts/harness.sh                                   # app on a throwaway copy of ~/.allman + fake CLI
scripts/harness.sh ALLMAN_SNAPSHOT_DIR=/tmp/shots ALLMAN_SNAPSHOT_CONV=Jamie \
    ALLMAN_SNAPSHOT_SEND="hello" FAKE_SEND_DELAY=3   # a fake send, captured every ~100 ms
```

`scripts/fake-allman.sh` stands in for the CLI (`send` appends to the thread's JSONL after a delay,
`FAKE_SEND_FAIL=1` makes it fail; `enrich`, `connections` and `connect` are simulated against the
store copy), so sends, failures and network jobs can be exercised and screenshotted without
touching LinkedIn or the real store. The Network view says when it is running against the fake CLI.

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
- **Media** (images, files, voice notes, video) is downloaded by `allman media <conv> --json` when a
  thread opens and rendered from `{conv}/media/` on disk: images inline (click to open in Preview), files as
  openable chips, voice notes with a player, video with AVKit. The app never fetches LinkedIn's CDN itself.
- **Writes** are `allman send … --json` (with `--reply-to` for quoted replies), `allman react … --json`,
  `allman read <target> --json` (when you open a thread, so linkedin.com matches), `allman sync <conv> --json`
  (history backfill on first open, and a small re-pull so reactions changed elsewhere show up), and
  `allman login`. Compose search uses `allman people <query> --json`. Every call gets `--store` and `--account`.
- **Live** state comes from a long-running `allman listen`: `connected`/`heartbeat` drive the status
  item; `message.received` posts a notification. The engine kills and restarts the subprocess when
  the network path changes, on wake from sleep, or after four minutes without a heartbeat.
- **Unread** combines LinkedIn's state with app-owned watermarks (Application Support/Allman/read-state.json,
  which also holds pins): LinkedIn's read state wins whenever it is at least as new as the newest message;
  otherwise a thread is unread when its newest message is inbound and you haven't opened it here. Opening a
  thread marks it seen locally and on LinkedIn through the CLI; nothing is written to the store by the app.

## Binary resolution

Settings override → `ALLMAN_BIN` → bundled `Contents/Resources/allman` → `~/.local/bin/allman` →
`/opt/homebrew/bin`, `/usr/local/bin` → `PATH`.

## Keyboard

| Key | Action |
| --- | --- |
| `⌘I` (panel) | Open the inbox |
| `⌘N` | New message |
| `⌘1` / `⌘2` / `⌘3` / `⌘4` | Messenger / Network / Insights / Settings |
| `↑` / `↓` or `j` / `k` | Move through the list (when it has focus) |
| `e` / `h` / `l` / `n` (list) | Archive / snooze / labels / note for the selected thread |
| `u` / `i` (list) | Toggle unread-only / contact details |
| `⌘↓` / `⌘↑` | Next / previous conversation from anywhere |
| `⌥⌘↓` / `⌥⌘↑` | Next / previous unread |
| `↩` or `Space` (list) | Jump to the message field; `Esc` goes back to the list |
| `⌘F` / `⌘L` | Focus search / the message field |
| `⇧⌘P` | Pin or unpin the open thread |
| `⇧⌘L` / `⇧⌘H` / `⇧⌘N` | Labels / snooze & remind / note |
| `⌘E` | Archive or unarchive |
| `⇧⌘Z` | Undo the last archive or snooze |
| `⇧⌘S` | Insert a snippet |
| `⌥⌘I` | Show or hide contact details |
| `↩` | Send (`⌥↩` for a newline) |
| `⌘R` | Sync the last day |
| `⇧⌘R` | Full re-sync of the last 7 days |
| `⌥⌘R` | Sync older history (pick a window or a date) |
| `⇧⌘U` | Toggle unread-only |
| `⇧⌘K` | Mark all as read |
| `⇧⌘O` | Open thread on linkedin.com |

## Development notes

- `open dist/Allman.app --env ALLMAN_SNAPSHOT_DIR=/tmp/shots` renders the inbox window (plus the
  swipe-reveal state and unread filter), the menu bar panel, the sign-in state and Settings to PNG and
  quits — useful for reviewing the UI without screen-recording permission. Add `ALLMAN_SNAPSHOT_CONV=<name>`
  to pick the thread, `ALLMAN_SNAPSHOT_COMPOSE=<query>` to capture the compose sheet,
  `ALLMAN_SNAPSHOT_SEARCH=<query>` for full-text search, `ALLMAN_SNAPSHOT_ORGANIZE=1` for labels,
  notes and reminders, `ALLMAN_SNAPSHOT_SNIPPETS=1` for the snippet picker, `ALLMAN_SNAPSHOT_NETWORK=1`
  for the Network window, `ALLMAN_SNAPSHOT_INSIGHTS=1` for the Insights sheet, and
  `ALLMAN_SNAPSHOT_PINS=a,b,c` to pin threads for the capture (restored afterwards).
- Notifications need the app to run from a real `.app` bundle (they do from `dist/` or Xcode).
- Launch at Login uses `SMAppService`; macOS may ignore it for apps outside `/Applications`.

## License

MIT — see [LICENSE](./LICENSE). Read [RESPONSIBLE_USE.md](./RESPONSIBLE_USE.md).
Named, like its siblings, in tribute to [Eric Allman](https://en.wikipedia.org/wiki/Eric_Allman).

## UI rules and the mock-data UI run

`docs/UI-RULES.md` lists the window's layout rules and how each is enforced.
`scripts/test.sh` runs the static rule checks, the unit tests, and a mock-data UI run:
the suite launches a second copy of the app on a synthetic store with the fake CLI and
the app drives its own window (real toolbar, clicks, key presses) and reports a verdict
per rule, with screenshots. `scripts/release.sh` runs the same gate.
