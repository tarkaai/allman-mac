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
| R6 | Thread header on the toolbar row, left-aligned: picture, name + messenger mark + degree, the brief on one line, **no location**. Hidden while the panel is open. | mock |
| R7 | Panel header on the top band above the panel (picture, name, pronouns, degree, Premium, verified) with the `i` beside it; it stays put while the panel body scrolls under it. | mock |
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
| R20 | No personal data in the repo: tests, fixtures and the mock store use obviously synthetic people (`*-example`, `*-sample`), never real names, slugs, ids or message text. | review on every change |
| R19 | Everything that touches LinkedIn goes through the `allman` CLI; the app never writes into `~/.allman`; app-owned state lives in Application Support (`ALLMAN_APPSUPPORT` overrides it for tests/harness). | lint (R19) + code review |

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
