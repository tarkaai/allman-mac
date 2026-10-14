#!/usr/bin/env bash
# Static guards for docs/UI-RULES.md — the rules that are a matter of which modifier
# is used, so a stray edit can't bring back a hard toolbar line, a second window or
# a per-view toolbar. Run by scripts/test.sh and scripts/release.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0
say() { echo "check-rules: $*"; }
bad() { say "FAIL $*"; fail=1; }
ok() { say "ok   $*"; }

ui=Sources/Allman/UI
# R8: one toolbar treatment — the system background with the soft scroll fade; never hidden, never hard.
if command grep -rn "toolbarBackgroundVisibility(.hidden" Sources >/dev/null; then bad "R8 toolbarBackgroundVisibility(.hidden) found"; else ok "R8 no hidden toolbar background"; fi
if command grep -rn "scrollEdgeEffectStyle(.hard" Sources >/dev/null; then bad "R8 hard scroll edge found"; else ok "R8 no hard scroll edge"; fi
# Main-window columns only (popovers, sheets and the menu bar panel are not under the toolbar).
for f in $ui/Inbox/ConversationListView.swift $ui/Inbox/ThreadView.swift $ui/Inbox/ContactInspector.swift $ui/Inbox/InsightsView.swift $ui/Network/NetworkView.swift $ui/Settings/SettingsView.swift; do
  command grep -q "scrollEdgeEffectStyle(.soft" "$f" || bad "R8 $f has a scroll container without the .soft edge effect"
done
ok "R8 every main-window column uses the .soft edge effect"
# R5: the contact panel is a column in the detail, never the system inspector (it squeezes the split view).
if command grep -rn "\.inspector(" Sources >/dev/null; then bad "R5 .inspector( found"; else ok "R5 no system inspector"; fi
# R5/R6: the app draws its own chrome — no system toolbar items anywhere (they re-flow, overflow and wash content).
if command grep -rn "\.toolbar {\|ToolbarItem(" Sources >/dev/null; then bad "R5 system toolbar items found"; else ok "R5 no system toolbar items"; fi
command grep -q "windowStyle(.hiddenTitleBar)" Sources/Allman/App/AllmanApp.swift && ok "R5 hidden title bar (chrome is ours)" || bad "R5 title bar not hidden"
# R33: a menu bar app — closing the last window must not quit it.
command grep -q "applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }" Sources/Allman/App/AppDelegate.swift && ok "R33 last window closed does not quit" || bad "R33 applicationShouldTerminateAfterLastWindowClosed must return false"
# R4: our own sidebar toggle, fixed at the top-left.
command grep -q 'uiProbe("sidebar-toggle")' $ui/Inbox/InboxWindow.swift && ok "R4 own toggle present" || bad "R4 own toggle missing"
# R26: no messenger badge on list rows; R21: the thread actions live on the top band, not in the inbox bar.
python3 -I - $ui/Inbox/ConversationListView.swift <<'PY' || bad "R26/R21 inbox bar or rows carry what belongs elsewhere"
import sys,re
s=open(sys.argv[1]).read()
row=s[s.index("struct ConversationRow"):s.index("struct ", s.index("struct ConversationRow")+10)]
bar=s[s.index("struct InboxBar"):s.index("struct ", s.index("struct InboxBar")+10)]
bad=[]
if "MessengerBadge" in row: bad.append("ConversationRow shows a messenger badge")
if "ConversationActions(convId: inbox.selectedConvId, asMenu: false)" in bar: bad.append("InboxBar carries the thread actions")
print("\n".join(bad)); sys.exit(1 if bad else 0)
PY
ok "R26/R21 rows without badge; actions on the top band"
python3 -I - $ui/Inbox/ConversationListView.swift <<'PY' || bad "R29 hover actions must be labels · snooze · archive only"
import sys
s=open(sys.argv[1]).read()
b=s[s.index("struct RowActions"):s.index("struct ", s.index("struct RowActions")+10)]
sys.exit(1 if ('"pin"' in b or 'note.text' in b) else 0)
PY
ok "R29 hover actions: labels · snooze · archive"
command grep -q "struct ThreadActions" $ui/Inbox/InboxWindow.swift && ok "R21 ThreadActions on the band" || bad "R21 ThreadActions missing"
# R36/R37: every icon button goes through IconButton (hover + its own tooltip); bar icons only as hover-wrapped menu labels.
python3 -I - $(find $ui -name "*.swift") <<'PY' || bad "R36 icon buttons must use IconButton (hover + tooltip)"
import sys, re
bad = []
for path in sys.argv[1:]:
    if path.endswith("IconButton.swift"): continue
    lines = open(path).read().split("\n")
    for n, line in enumerate(lines, 1):
        if ("BarIcon(" in line or "BandIcon(" in line) and ".iconHover()" not in line:
            bad.append(f"{path}:{n}: bar icon outside IconButton without hover")
        if "Button" in line and ("BarIcon(" in line or "BandIcon(" in line):
            bad.append(f"{path}:{n}: Button wrapping a bar icon (use IconButton)")
print("\n".join(bad)); sys.exit(1 if bad else 0)
PY
ok "R36 icon buttons through IconButton (hover + one tooltip each)"
if command grep -rn "pickerStyle(.segmented)" $ui/Inbox/InboxWindow.swift >/dev/null; then bad "R37 the experience switcher must be per-button (own tooltips)"; else ok "R37 experience switcher is per-button"; fi
# R15b: the selected conversation is highlighted edge to edge (plain list style, not the inset sidebar style).
command grep -q "listStyle(.plain)" $ui/Inbox/ConversationListView.swift && ! command grep -q "listStyle(.sidebar)" $ui/Inbox/ConversationListView.swift && ok "R15b full-width selection (plain list)" || bad "R15b conversation list must use .plain"
# R13: one window — no Settings scene, no extra Window scenes.
app=Sources/Allman/App/AllmanApp.swift
if command grep -nE "^\s*Settings \{|Settings\(" "$app" >/dev/null; then bad "R13 Settings scene found"; else ok "R13 no Settings scene"; fi
n=$(command grep -cE "^\s*Window\(" "$app" || true); [[ "$n" == "1" ]] && ok "R13 exactly one Window scene" || bad "R13 expected one Window scene, found $n"
# R19: LinkedIn only through the CLI; the app never writes into the store.
if command grep -rn "linkedin.com/voyager\|/voyager/api" Sources >/dev/null; then bad "R19 direct LinkedIn API reference in Swift"; else ok "R19 no direct LinkedIn API calls"; fi
# R14: no Divider() in the inbox chrome outside menus (menus use it as a separator).
if python3 -I - $ui/Inbox/ConversationListView.swift $ui/Inbox/InboxWindow.swift $ui/Inbox/ThreadView.swift $ui/Inbox/ContactInspector.swift <<'PY'
import sys, re
bad = []
for path in sys.argv[1:]:
    stack = []  # one entry per open brace: True when the block is a menu
    for n, line in enumerate(open(path), 1):
        pending_menu = bool(re.search(r"(Menu \{|contextMenu \{|Picker\(|RightClickMenu \{|menu: \{)", line))
        if "Divider()" in line and not any(stack):
            bad.append(f"{path}:{n}: {line.strip()}")
        for ch in line:
            if ch == "{": stack.append(pending_menu); pending_menu = False
            elif ch == "}" and stack: stack.pop()
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
then ok "R14 no dividers in the inbox chrome (menus excepted)"; else bad "R14 Divider() outside a menu"; fi
[[ $fail == 0 ]] && say "all rules hold" || { say "rule violations"; exit 1; }
