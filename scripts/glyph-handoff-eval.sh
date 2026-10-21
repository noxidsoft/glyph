#!/usr/bin/env bash
# Does memory survive a handoff BETWEEN TWO AGENT SESSIONS?
#
# glyph-memory-eval.sh seeds the store with the CLI, so it only tests the read
# half. This tests the loop that actually matters in practice:
#
#   session 1 (agent)  does work, decides something, records it
#   session 2 (agent)  cold start, is asked about it, must retrieve it
#
# Each phase is a separate `claude -p` process: no shared context, no shared
# conversation, only the store on disk between them. The nonce means phase 2
# cannot know the answer from training, the repo, or its own prompt.
#
# Usage: ./scripts/glyph-handoff-eval.sh [--keep]
set -uo pipefail

GLYPH="${GLYPH:-$HOME/go/bin/glyph}"
KEEP=${1:-}
WORK="$(mktemp -d)"
[ "$KEEP" = --keep ] || trap 'rm -rf "$WORK"' EXIT
NONCE="$RANDOM$RANDOM"

command -v claude >/dev/null || { echo "claude CLI not on PATH"; exit 2; }
[ -x "$GLYPH" ] || { echo "glyph not executable at $GLYPH (set GLYPH=...)"; exit 2; }

cd "$WORK"; git init -q .
"$GLYPH" init >/dev/null
echo "workdir $WORK   nonce $NONCE"
echo

glyph_calls() {  # count tool calls that touched glyph
  python3 - "$1" <<'PYEOF'
import json,re,sys
# A real glyph invocation -- not merely the word "glyph" inside a path, which
# made `ls ~/.claude/skills/glyph` count as memory usage and inflated results.
SUB = r"(init|etch|amend|ask|show|list|link|related|forget|context|skill|model)"
RX  = re.compile(r"(?:^|[;&|]\s*|\s)(?:[\w./$~{}-]*/)?glyph\s+" + SUB + r"\b")
n = 0
for line in open(sys.argv[1]):
    try: ev = json.loads(line)
    except ValueError: continue
    if ev.get("type") == "assistant":
        for b in ev.get("message", {}).get("content", []):
            if b.get("type") == "tool_use" and RX.search(str(b.get("input", {}).get("command", ""))):
                n += 1
print(n)
PYEOF
}
answer_of() {
  python3 - "$1" <<'PY'
import json,sys
t=[]
for line in open(sys.argv[1]):
    try: ev=json.loads(line)
    except ValueError: continue
    if ev.get("type")=="assistant":
        for b in ev.get("message",{}).get("content",[]):
            if b.get("type")=="text": t.append(b["text"])
    elif ev.get("type")=="result" and ev.get("result"): t.append(str(ev["result"]))
print(" ".join(t))
PY
}

echo "--- PHASE 1: session 1 records a decision -------------------------------"
# The seeded fact is a config revision, not a quantity: a random nonce used as
# a magnitude (e.g. "${NONCE} basis points") is correctly flagged as implausible
# by the writing agent, which pollutes the signal being measured.
claude -p "We just finished the deploy review. The decision: deploys are gated \
on canary config revision ${NONCE}, because the previous revision let bad \
builds reach too much traffic. Record this in project memory so a future \
session can find it. Then stop." \
  --output-format stream-json --verbose > p1.jsonl 2>p1.err
echo "    rc=$?  glyph calls=$(glyph_calls p1.jsonl)"
WROTE=$("$GLYPH" ask "canary config revision deploy gate" --facet id 2>/dev/null | tr '\n' ' ')
echo "    store now holds: $("$GLYPH" context 2>/dev/null | head -1)"
echo "    glyphs matching the topic: ${WROTE:-<none>}"
if [ -z "$WROTE" ]; then
  echo
  echo "FAIL at phase 1 — session 1 never wrote to the store. Nothing to hand off."
  echo "  (it may have written a NOTES.md or used built-in memory instead;"
  echo "   check: $WORK/p1.jsonl)"
  exit 1
fi
echo

echo "--- PHASE 2: session 2, cold, is asked ----------------------------------"
claude -p "Which canary config revision are deploys gated on, and why? \
Answer with the revision number." \
  --output-format stream-json --verbose > p2.jsonl 2>p2.err
A2=$(answer_of p2.jsonl); C2=$(glyph_calls p2.jsonl)
echo "    rc=$?  glyph calls=$C2"
echo
echo "$A2" | head -6
echo
case "$A2" in *"$NONCE"*) FOUND=yes ;; *) FOUND=no ;; esac
echo "nonce recalled : $FOUND  ($NONCE)"
echo "glyph calls    : $C2"
echo
if [ "$FOUND" = yes ] && [ "$C2" -gt 0 ]; then
  echo "PASS — the decision survived an agent-to-agent handoff through the store."
elif [ "$FOUND" = yes ]; then
  echo "SUSPECT — recalled without calling glyph. Check how it got the number."
else
  echo "FAIL — session 1 wrote it, session 2 did not retrieve it."
fi
[ "$KEEP" = --keep ] && echo && echo "kept: $WORK"
