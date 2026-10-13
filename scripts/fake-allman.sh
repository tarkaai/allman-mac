#!/usr/bin/env bash
# A stand-in for the allman CLI so the app can be exercised without LinkedIn.
# Reads and writes a throwaway store (see scripts/harness.sh); `send` appends
# a message to the thread's JSONL after a delay, just like the real CLI's
# write lands before its process exits.
#
#   FAKE_SEND_DELAY=2     seconds before `send` returns (default 2)
#   FAKE_SEND_WRITE_DELAY seconds before `send` writes the message to the store (default: same as
#                         FAKE_SEND_DELAY). The real CLI writes first and exits later, so the file
#                         watcher reloads the thread before the process returns.
#   FAKE_SEND_FAIL=1      make `send` fail with an HTTP 500 after the delay
set -euo pipefail

account=""; store=""; cmd=""; rest=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --account) account="$2"; shift 2 ;;
    --store) store="$2"; shift 2 ;;
    --version) echo "0.5.0-fake"; exit 0 ;;
    *) if [[ -z "$cmd" ]]; then cmd="$1"; else rest+=("$1"); fi; shift ;;
  esac
done
[[ -n "$store" ]] || { echo "fake-allman: --store required" >&2; exit 2; }

account_dir() {
  if [[ -n "$account" && -e "$store/$account" ]]; then
    (cd "$store/$account" && pwd -P)
  else
    ls -d "$store"/ACo*/ 2>/dev/null | head -1 | sed 's#/$##'
  fi
}
now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
json_field() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); v=d.get(sys.argv[2]); print("" if v is None else v)' "$1" "$2"; }

acct="$(account_dir)"
case "$cmd" in
  status)
    pid="$(basename "$acct")"
    slug="$(json_field "$acct/AUTH.json" profileSlug)"
    name="$(json_field "$acct/AUTH.json" name)"
    printf '[{"profileId":"%s","slug":"%s","name":"%s","status":"authenticated","cookiesValid":true}]\n' "$pid" "$slug" "$name"
    ;;
  whoami)
    printf '{"profileId":"%s","refreshed":false}\n' "$(basename "$acct")"
    ;;
  listen)
    printf '{"event":"connected","timestamp":%s}\n' "$(now_ms)"
    while true; do sleep 30; printf '{"event":"heartbeat","timestamp":%s}\n' "$(now_ms)"; done
    ;;
  sync)
    printf '{"event":"sync.complete","conversationsSynced":0,"messagesSynced":0}\n'
    ;;
  send)
    target="${rest[0]}"; body=""; audio=""; duration=0
    i=1; while [[ $i -lt ${#rest[@]} ]]; do
      case "${rest[$i]}" in
        --audio) audio="${rest[$((i+1))]}"; i=$((i+2)) ;;
        --duration-ms) duration="${rest[$((i+1))]}"; i=$((i+2)) ;;
        --*) i=$((i+1)) ;;
        *) [[ -z "$body" ]] && body="${rest[$i]}"; i=$((i+1)) ;;
      esac
    done
    total="${FAKE_SEND_DELAY:-2}"; write_after="${FAKE_SEND_WRITE_DELAY:-$total}"
    sleep "$write_after"
    if [[ "${FAKE_SEND_FAIL:-0}" == "1" ]]; then echo "LinkedIn API error: HTTP 500" >&2; exit 1; fi
    # The rest of the wait happens after the write (see the end of this case).
    remaining="$(python3 -c "print(max(0.0, float('$total') - float('$write_after')))")"
    # Several targets (a,b,c): a new group thread, like `allman send` ≥ 0.6.
    if [[ "$target" == *,* ]]; then
      python3 - "$acct" "$target" "$body" <<'EOFG'
import json, os, sys, time, datetime
acct, targets, body = sys.argv[1], sys.argv[2].split(","), sys.argv[3]
now_ms = int(time.time() * 1000)
iso = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
auth = json.load(open(os.path.join(acct, "AUTH.json")))
parts = []
for t in targets:
    rec = None
    p = os.path.join(acct, t)
    if os.path.isdir(p):
        try: rec = json.load(open(os.path.join(p, "RECORD.json")))
        except Exception: rec = None
    name = (rec or {}).get("name") or t.replace("-", " ").title()
    first, _, last = name.partition(" ")
    pid = (rec or {}).get("profileId") or "ACoAAFAKE" + t.upper().replace("-", "")[:12]
    parts.append({"profileId": pid, "profileUrn": "urn:li:fsd_profile:" + pid, "backendUrn": None, "slug": t,
                  "firstName": first, "lastName": last, "name": name, "headline": (rec or {}).get("headline"), "profileUrl": "https://www.linkedin.com/in/" + t,
                  "profilePictures": (rec or {}).get("profilePictures"), "distance": "DISTANCE_1", "pronoun": None, "memberBadgeType": None, "isPremium": False, "isVerified": False})
conv_id = "2-FAKEGROUP%d==" % now_ms
d = os.path.join(acct, conv_id); os.makedirs(os.path.join(d, "messages"), exist_ok=True)
first = parts[0]
record = {"convId": conv_id, "profileId": first["profileId"], "slug": None,
          "convUrn": "urn:li:msg_conversation:(%s,%s)" % (auth.get("urn"), conv_id), "backendUrn": "urn:li:messagingThread:" + conv_id,
          "profileUrn": first["profileUrn"], "memberUrn": None, "firstName": first["firstName"], "lastName": first["lastName"],
          "name": ", ".join(p["name"] for p in parts), "headline": first["headline"], "profileUrl": first["profileUrl"], "profilePictures": first["profilePictures"],
          "distance": "DISTANCE_1", "pronoun": None, "memberBadgeType": None, "isPremium": False, "isVerified": False,
          "unreadCount": 0, "lastActivityAt": iso, "lastReadAt": iso, "createdAt": iso, "read": True, "notificationStatus": "ACTIVE",
          "categories": ["INBOX", "PRIMARY_INBOX"], "conversationUrl": "https://www.linkedin.com/messaging/thread/%s/" % conv_id, "disabledFeatures": [],
          "isGroup": True, "title": None, "participants": parts,
          "syncState": {"oldestMessageAt": now_ms, "newestMessageAt": now_ms, "lastSyncAt": iso, "totalSynced": 1, "fullyBackfilled": True}, "fetchedAt": iso}
json.dump(record, open(os.path.join(d, "RECORD.json"), "w"), indent=2)
urn = "urn:li:messagingMessage:fake-%d" % now_ms
with open(os.path.join(d, "messages", time.strftime("%Y-%m") + ".jsonl"), "a") as out:
    out.write(json.dumps({"urn": urn, "timestamp": now_ms, "fromUrn": auth.get("urn"), "fromName": auth.get("name"), "isFromMe": True, "body": body, "reactions": [], "attachments": [], "originToken": None}) + "\n")
print(json.dumps({"messageUrn": urn, "conversationUrn": "urn:li:messagingThread:" + conv_id, "sentAt": now_ms, "recipients": targets}))
EOFG
      sleep "$remaining"
      exit 0
    fi
    # Resolve the thread: slug/id entry in the account dir, else a RECORD.json mentioning it.
    conv=""
    if [[ -e "$acct/$target" ]]; then conv="$(cd "$acct/$target" && pwd -P)"
    else conv="$(grep -ls -- "$target" "$acct"/2-*/RECORD.json 2>/dev/null | head -1 | xargs -I{} dirname {})"; fi
    [[ -n "$conv" && -d "$conv" ]] || { echo "fake-allman: conversation $target not found" >&2; exit 1; }
    # Some stores carry a legacy slug *directory* beside the 2-… conversation dir; write where the app reads.
    cid="$(json_field "$conv/RECORD.json" convId 2>/dev/null || true)"
    if [[ -n "$cid" && -d "$acct/$cid" ]]; then conv="$acct/$cid"; fi
    ts="$(now_ms)"
    urn="urn:li:messagingMessage:fake-$ts"
    me="$(json_field "$acct/AUTH.json" urn)"; name="$(json_field "$acct/AUTH.json" name)"
    file="$conv/messages/$(date +%Y-%m).jsonl"; mkdir -p "$conv/messages"
    attachments="[]"
    if [[ -n "$audio" ]]; then
      mkdir -p "$conv/media"
      cp "$audio" "$conv/media/fake-$ts-0.${audio##*.}"
      attachments="[{\"type\":\"voice\",\"durationMs\":$duration,\"name\":\"$(basename "$audio")\",\"mimeType\":\"audio/mp4\"}]"
    fi
    python3 - "$file" "$urn" "$ts" "$me" "$name" "$body" "$attachments" <<'EOF'
import json, sys
f, urn, ts, me, name, body, attachments = sys.argv[1:]
with open(f, "a") as out:
    out.write(json.dumps({"urn": urn, "timestamp": int(ts), "fromUrn": me, "fromName": name, "isFromMe": True,
                          "body": body, "reactions": [], "attachments": json.loads(attachments), "originToken": None}) + "\n")
EOF
    sleep "$remaining"
    printf '{"messageUrn":"%s","conversationUrn":"urn:li:messagingThread:%s","sentAt":%s}\n' "$urn" "$(basename "$conv")" "$ts"
    ;;
  read|react|media|logout|login) printf '{}\n' ;;
  people) printf '[]\n' ;;
  connections)
    # Pretend to page through the list; nothing is written.
    echo "Fetching connections (page size 100, limit ∞)…" >&2
    for i in 1 2 3; do sleep 1; echo "Page $i: $((i * 100)) so far…" >&2; done
    echo "✓ Stored 300 connections." >&2
    ;;
  enrich)
    # `enrich <slug>` stamps that record; bulk mode stamps up to --limit un-enriched records.
    target=""; limit=3
    i=0; while [[ $i -lt ${#rest[@]} ]]; do
      case "${rest[$i]}" in --limit) limit="${rest[$((i+1))]}"; i=$((i+2)) ;; --*) i=$((i+1)) ;; *) target="${rest[$i]}"; i=$((i+1)) ;; esac
    done
    python3 - "$acct/connections" "$target" "$limit" <<'EOF2'
import json, os, sys, time, datetime
d, target, limit = sys.argv[1], sys.argv[2], int(sys.argv[3])
now = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
files = []
if target:
    p = os.path.join(d, target)
    if os.path.islink(p): p = os.path.join(d, os.readlink(p))
    files = [p] if os.path.isfile(p) else []
    if not files:
        files = [os.path.join(d, target + ".json")]
        if not os.path.isfile(files[0]): print(f"✗ {target}: not found in the store", file=sys.stderr); sys.exit(1)
else:
    for n in sorted(os.listdir(d)):
        p = os.path.join(d, n)
        if not n.endswith(".json") or os.path.islink(p): continue
        try: r = json.load(open(p))
        except Exception: continue
        if not r.get("enrichedAt"): files.append(p)
        if len(files) >= limit: break
for p in files:
    time.sleep(1)
    r = json.load(open(p))
    r.setdefault("title", "Founder"); r.setdefault("company", "Fake Co"); r.setdefault("location", "Seattle, Washington, United States")
    r["about"] = r.get("about") or "Enriched by the harness."; r["enrichedAt"] = now; r["enrichDepth"] = "deep"
    json.dump(r, open(p, "w"), indent=2)
    print(json.dumps({"flagshipId": r.get("flagshipId"), "title": r["title"], "company": r["company"], "enrichDepth": "deep"}))
print(f"Enriched {len(files)}, skipped 0, 0 failed.", file=sys.stderr)
EOF2
    ;;
  connect)
    target="${rest[0]}"; note=""
    i=1; while [[ $i -lt ${#rest[@]} ]]; do case "${rest[$i]}" in --note) note="${rest[$((i+1))]}"; i=$((i+2)) ;; *) i=$((i+1)) ;; esac; done
    sleep 1
    mkdir -p "$acct/invitations"
    python3 - "$acct/invitations" "$target" "$note" <<'EOF2'
import json, sys, datetime
d, slug, note = sys.argv[1:]
now = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
inv = {"inviteeId": "fake-" + slug, "inviteeUrn": "urn:li:fsd_profile:fake-" + slug, "publicIdentifier": slug, "note": note or None, "invitationUrn": "urn:li:fsd_invitation:fake", "sentAt": now}
json.dump(inv, open(f"{d}/fake-{slug}.json", "w"), indent=2)
print(json.dumps({"invitationUrn": inv["invitationUrn"], "inviteeUrn": inv["inviteeUrn"], "note": inv["note"]}))
EOF2
    ;;
  *) echo "fake-allman: unhandled command $cmd" >&2; exit 1 ;;
esac
