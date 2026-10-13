# Allman for Mac — UI rules

The user's layout and behaviour rules for the main window, collected from every
feedback round (latest wins where they conflicted). Each rule names how it is
enforced: **mock** = `UIRulesTests` drives a second copy of the app on a synthetic
store (`Tests/AllmanTests/MockStore.swift`) through `UIRuleChecks` — real toolbar,
real clicks, real key presses — and asserts the verdicts; **lint** =
`scripts/check-rules.sh` (runs in `scripts/test.sh` and `scripts/release.sh`).
Screenshots of every checked state are written next to the test's result JSON.

| Rule | What must hold | Proof |
|---|---|---|
| R1 | Sidebar order, top to bottom: chrome bar (toolbar row) → inbox bar (title, actions, inbox chips) → search → pins → list → signed-in account at the very bottom. | mock |
| R2 | Labeled inboxes are chips with **icons**, not colors, above the search field. A thread can be in many inboxes. | mock (R1 geometry) + `OrganizerTests` |
| R3 | Pins belong to the inbox on screen and never also appear in the list. Clicking a pin selects it without the list showing it too. | mock |
| R4 | The chrome bar (our own sidebar toggle at the **far left**, then the Messenger · Network · Insights · Settings switcher) is fixed at the top-left of the window. Collapsing the sidebar changes only the toggle's look — nothing moves, nothing is duplicated; the page header shifts right to clear it. No system toolbar at all. | mock + lint |
| R5 | Exactly **one** contact-panel control: the `i`, far right of the window, same glyph open or closed, never moves (it is the window's, not a column's), and clicking it toggles the panel. The panel is a column inside the detail (never `.inspector`, which squeezes the split view mid-animation and makes the sidebar jump). The app draws its own chrome: hidden title bar, no `.toolbar` items anywhere (they re-flow, overflow and wash content in the band). | mock + lint |
| R6 | Thread header on the top band, left-aligned: picture, name + messenger mark + degree, the brief on one line, **no location**. It never moves and never hides — not when the panel opens, not when the sidebar collapses. | mock |
| R7 | The contact panel has **no header of its own**; its body starts under the band (the thread actions and the `i` sit above it). | mock |
| R8 | One top-band treatment everywhere: page headers are `safeAreaBar`s and content scrolls under them with the **soft** scroll-edge fade. Never a hidden/painted toolbar background, never `.hard`. Every main-window column uses `.scrollEdgeEffectStyle(.soft, for: .top)`. | lint |
| R9 | Keyboard moves (j/k, ⌘↑/↓) keep the selected row visible with the **least** movement: one step down from the top does not scroll; a long run brings the row to the edge. No visual jumps. | mock |
| R10 | Choosing an inbox the open thread is not in clears the selection. | mock |
| R11 | Opening a thread never focuses the composer; the list keeps focus so j/k/e/h/l/n/u/i work. | mock |
| R12 | Group threads appear in the list, named by their members (or LinkedIn's title), stacked avatars, sender names in the stream, send/read by bare conversation id. | mock + `StoreReaderTests` |
| R13 | One window. Network, Insights and Settings are experiences inside it (⌘1–⌘4, ⌘,); no Settings scene, no secondary windows. | mock + lint |
| R13b | The sidebar's collapsed state is remembered **per page**; Settings never collapses its sidebar (the toggle is disabled there). | mock |
| R3b | The sidebar is the full height of the window, over the top band; the signed-in account is a bottom inset of it. | mock |
| R15b | The selected conversation is highlighted edge to edge — no horizontal inset, no rounded corners (plain list style). | lint |
| R12b | A new message to two or more people creates a **group thread** through `allman send a,b` (chips in the draft, "Add people"). | mock + fake CLI |
| R14 | No `Divider()` in the inbox chrome (menus use separators; that's fine). | lint |
| R15 | Icons on the inbox bar are `BarIcon` (24×22, one weight); text on the `AFont` scale. | review |
| R16 | Row hover actions overlay the time stamp — no layout shift, no flicker. | review |
| R17 | The thread opens on the newest message and stays there when the panel opens/closes or the window resizes. | mock |
| R18 | Animations: panel open/close, sidebar collapse and experience switch are single eased transitions; nothing else in the window moves. While the panel slides the thread lays out frame by frame with no animations of its own (no text crossfading at a different pace than the bubbles). | mock (R5/R17 frames) + screenshots |
| R21 | The open thread's actions (pin · labels · snooze/remind · note · archive) sit on the top band beside the `i`, same size, same row, whether the panel is open or closed. They are not in the inbox bar. | mock + lint |
| R22 | "Needs my reply" counts your reaction on their last message as a reply. | mock |
| R23 | Pinned threads stay in the sidebar whatever the filter (a label inbox shows its own pins). | mock |
| R24 | A click on a visible row never scrolls the list; selecting a search result keeps the result order and position; a new message to someone who already has a thread opens that thread, highlighted and on screen. Only keyboard/menu/notification/draft selections scroll the list. | mock |
| R25 | The filter icon sits left of the inbox title. | mock |
| R26 | No messenger badge on list rows (it stays in the thread header and account block). | lint |
| R27 | Groups of three or more are named after all members and their stacked avatar carries a "+N" badge. | mock |
| R30 | Sending is one motion: the bubble rises from the composer into the feed once, the stream stays pinned at every frame, and the stored copy takes over the *same* row (same identity, same position and size) — the status flips "Sending…" → "Sent" in place; nothing is removed, re-inserted or duplicated, and nothing above it moves either (a placeholder counts as the next message when the previous bubble's tail is decided; a 10 ms trace of bubble, caption, composer and bottom edge must be constant through the flip). The stored copy is picked up from the store by the file watcher before the CLI process returns. | mock (80 samples at 50 ms; fake CLI writes at 0.4 s and returns at 3 s, like the real one) |
| R31 | The row hover capsule (labels · snooze · archive) is centered on its row and its icons are centered in it. | mock |
| R27b | Group avatars pack every face inside one avatar-sized circle (two on a diagonal, three in a triangle); four or more add "+N". | mock + screenshot |
| R32 | Opening the contact panel narrows the thread at the pace the panel appears (no jump, then slide); bubbles are sized for the detail with the panel closed, so mostly whitespace collapses. | mock |
| R33 | The thread header keeps its full width when the panel opens; it may use the whole column before truncating. | mock |
| R34 | The new-message button sits at the top-right of the sidebar on the band (beside the chrome bar once the sidebar is collapsed), always visible; from any page it switches to the inbox and starts a new message. Its instructions wrap and say search starts after two characters. | mock |
| R4b | Every icon button's symbol name must exist (a misspelt name renders as nothing). | mock |
| R32b | Collapsing or opening the sidebar, like the panel, shifts the thread gradually and never re-wraps bubbles — bubbles are sized for the sidebar-open, panel-closed width. | mock |
| R35b | Switching the insights window never blanks the page; tiles stay and their numbers animate to the new values. | mock |
| R35 | Insights are per account (sidebar lists every signed-in account) over a window of time — all time, past year/month/week/day by calendar days, or a custom number of days; the header is two lines (page + account). | mock + unit |
| R36 | Every icon button has the same hover highlight and its own tooltip (`IconButton`); no tooltips for a whole group. | lint |
| R37 | Glass, not gray: the account block and the new-message pane use the blur material over the list. | review |
| R32c | Opening/closing the panel and collapsing the sidebar never shift the messages (the bottom edge stays put at every frame) and never scroll programmatically. | mock |
| R38 | Switching pages (⌘1–⌘4) is immediate: the page's header is on screen within 150 ms and the main thread's first turn is short; data (rows, numbers) fills in afterwards with loading/empty states. | mock (12,000 mock connections) |
| R28 | Every conversation row is the same height (two preview lines always reserved) and the avatar is vertically centered. | mock |
| R29 | Row hover actions are labels · snooze · archive only (pin and note live on the top band). | lint |
| R6b | The thread header keeps its exact place whether the sidebar is open or collapsed, and is not jammed against the top edge (52pt band). | mock |
| R20 | No personal data in the repo: tests, fixtures and the mock store use obviously synthetic people (`*-example`, `*-sample`), never real names, slugs, ids or message text. | review on every change |
| R19 | Everything that touches LinkedIn goes through the `allman` CLI; the app never writes into `~/.allman`; app-owned state lives in Application Support (`ALLMAN_APPSUPPORT` overrides it for tests/harness). | lint (R19) + code review |

## Running quietly

A test run never takes your focus: the XCTest host has no window, no status item and starts
no CLI processes, and the mock run's window is ordered front once without becoming key or
activating the app (clicks and keys are sent straight to that window). It appears behind
whatever you are doing and goes away when the run ends.

## Running

```sh
scripts/check-rules.sh          # lint rules, < 1 s
scripts/test.sh                 # lint + unit tests + the mock-data UI run (≈ 2 min)
```

The UI run can also be driven by hand on any store:

```sh
ALLMAN_STORE=/path/to/store ALLMAN_BIN=scripts/fake-allman.sh ALLMAN_APPSUPPORT=/tmp/support \
ALLMAN_UICHECK_OUT=/tmp/result.json ALLMAN_UICHECK_SHOTS=/tmp/shots \
build/Build/Products/Debug/Allman.app/Contents/MacOS/Allman
```

## Known gap

Selecting a thread right after an inbox switch rebuilt the list can leave the first
row just above the visible edge (the List's `.top`-anchored scroll lands high); the
keyboard then corrects it on the next move. Tracked in `UIRuleChecks` as an
informational check, not a gate.
