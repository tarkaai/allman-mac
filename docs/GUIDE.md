# Using Allman for Mac

Allman for Mac is a native inbox for LinkedIn messaging, built on the local store that the
[`allman`](https://github.com/tarkaai/allman-cli) CLI keeps in `~/.allman`. This guide covers
the window, the inbox organization features, the Network experience, the menu bar item,
accounts and the keyboard. For building and contributing, see [DEVELOPMENT.md](./DEVELOPMENT.md).

## The window

One window, four experiences (`⌘1`–`⌘4`): **Messenger**, **Network**, **Insights**,
**Settings**. The switcher sits on the top bar beside the sidebar toggle. Every experience has
the same shape: the sidebar carries that experience's navigation, with the signed-in account at
the bottom (the chevron reveals account actions: switch, sync, sync older history, add, sign
out, settings); the page's header sits on the top bar, and the page's actions are on the right.
There is no separate Settings window.

### Messenger

The sidebar holds the inbox bar, search, pinned threads and the list:

- **Inbox bar.** Every label is an inbox, shown as icon chips next to *All* and *Unread*,
  with the filter menu on the left and *New label* on the right.
- **Search** ranks by relevance: an exact or prefix match on the name first, then a word
  prefix or initials, then handle / headline / company, then a substring of the last message.
  From three characters it also scans every stored message body (what `allman grep` does) and
  lists hits under *Messages*; opening a hit jumps the thread to that message.
- **Pins** for the current inbox sit above the list, Messages-style. Pinned threads stay
  visible under every filter.
- **The list.** Rows are uniform height with a two-line preview. Hovering a row reveals
  labels / snooze / archive; trackpad swipes work Mail-style: right for read / pin, left for
  archive / snooze / label.
- **New Message** (`⌘N`, or the compose button at the top of the sidebar) turns the search
  field into a people search across your conversations, your connections, LinkedIn
  (`allman people`) or a pasted profile link. Picking someone opens a draft; add more people
  to start a group thread.

The thread header is about the person: name with the messenger's mark (LinkedIn today;
Allman is built for more than one), their headline and location. The thread's actions (pin,
label, snooze, note, archive) sit at the top right, next to the `i` that opens the contact
panel. Group threads show every member's face in one avatar and caption each inbound message
with its sender.

Messages render iMessage-style: blue and gray bubbles, swipe to reveal times, link previews,
LinkedIn reactions and quoted replies, images inline, files as openable chips, voice notes with
a player and transcript, video with AVKit.

## Inbox organization

All of this is app-owned, per account, under `~/Library/Application Support/Allman/`. Nothing
is written to the CLI's store, so its git history stays clean.

- **Labels** tag a thread with any number of labels (`L` or `⇧⌘L`). Each label is its own
  inbox with an SF Symbol icon. Rename, change the icon or delete from a chip's context menu.
- **Notes** keep context on a person (`N` or `⇧⌘N`), in the contact panel or a popover.
- **Snooze** (`H` or `⇧⌘H`) hides a thread until a time; it comes back early if they write.
  **Remind** keeps it in place and pings you at the time. Due reminders post a notification,
  show a banner in the thread and a bell in the list; the clock chip lists them.
- **Archive** (`E` or `⌘E`) clears a thread; a new message brings it back. Archive and snooze
  show a toast with Undo (`⇧⌘Z`).
- **Snippets** (`⇧⌘S`, the quote button, or a lone `/` in an empty field) insert saved replies
  with `{firstName} {lastName} {name} {slug} {company} {title} {me}` filled in. Manage them in
  Settings → Snippets. They share allman-tui's template format and are seeded from
  `~/.config/allman-tui/templates.json` on first launch.
- **Voice notes** are transcribed on this Mac with the Speech framework (no network) the first
  time they're shown. Toggle in Settings → Behavior. Record one with the mic in an empty message
  field (Return to stop, listen back, Return to send); it goes out through `allman send --audio`.
- **Pictures are cached** (profile photos, link previews) under `~/Library/Caches/Allman` for
  30 days, keyed on the CDN path so refreshed tokens still hit; see Settings → Store.
- **Export** (File menu) writes every conversation with labels and notes as CSV, or the open
  thread as Markdown.
- **Contact panel** (`I` or `⌥⌘I`) shows pronouns, degree, role, location, about, experience,
  education and skills from the connections store once `allman enrich` has run; *Fetch profile
  details* runs `allman enrich <slug> --deep` for one person.

## Insights

`⌘3` shows sent and received volume, reply rate and median reply time, threads waiting on you,
messages per week and your most active contacts. Pick an account in the sidebar and a range at
the top: all time, past year, month, week, day (calendar days, not rolling hours) or a custom
number of days.

## Network

`⌘2` shows your stored 1st-degree network as a sortable, searchable table (name, title,
company, location, connected date, enrichment) with *Message*, *Open profile* and *Fetch
details* per row. The page drives the CLI's network jobs with live progress: **Pull
Connections** (`allman connections`), **Enrich** up to N profiles
(`allman enrich --json --limit N [--deep]`) and **Connect…** (`allman connect <slug> [--note …]`,
with the 300-character cap, the CLI's duplicate / already-invited checks and its daily quota).
*Invitations sent* lists what `invitations/` records. The compose search offers *Connect* on
2nd/3rd-degree LinkedIn results.

## Menu bar and accounts

- **Click** the menu bar icon to open the inbox; **right-click** (or control-click) for the
  status panel: who is signed in, live/sync state, recent activity, Launch at Login, Settings,
  Quit.
- The panel and the sidebar show your own LinkedIn profile (photo, name, headline). The app
  runs `allman whoami --refresh` once per launch so `AUTH.json` carries them.
- **Several accounts** can be signed in at once: every account keeps its own `allman listen`
  and periodic sync and sends notifications; the window shows one at a time. Switch from the
  account at the bottom of the sidebar, the panel header, or the Inbox menu; add one with
  **Add Account…** (runs `allman login` for a new profile; *Options…* adds
  `--proxy host:port[:user:pass]` or `--no-salesnav`) and sign out from Settings → Accounts
  (`allman logout`). Read watermarks, pins, labels and notes are kept per account.
- **Unread** combines LinkedIn's state with app-owned watermarks. LinkedIn's read state wins
  whenever it is at least as new as the newest message; otherwise a thread is unread when its
  newest message is inbound and you haven't opened it here. Opening a thread marks it seen
  locally and on LinkedIn through `allman read`.

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
