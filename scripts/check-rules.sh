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
# R5/R6: toolbar items are declared in the page containers only — never per thread or in the panel.
for f in $ui/Inbox/ThreadView.swift $ui/Inbox/ContactInspector.swift $ui/Inbox/ConversationListView.swift; do
  command grep -q "\.toolbar {" "$f" && bad "R5 $f declares toolbar items (must live in InboxWindow/page views)" || true
done
ok "R5 toolbar items only in page containers"
# R4: our own sidebar toggle at the far left, the system one removed.
command grep -q "toolbar(removing: .sidebarToggle)" $ui/Inbox/InboxWindow.swift && ok "R4 system sidebar toggle removed" || bad "R4 system sidebar toggle not removed"
command grep -q 'uiProbe("sidebar-toggle")' $ui/Inbox/InboxWindow.swift && ok "R4 own toggle present" || bad "R4 own toggle missing"
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
