#!/usr/bin/env bash
# Does a FRESH agent session choose to consult glyph memory?
#
# Persistence is not what this tests — the store is a SQLite file, so that is
# a given. This tests the only thing that can actually be decorative: whether
# an agent with the glyph skill installed reaches for it unprompted.
#
# Method: seed a fact that appears nowhere in any repo, prompt, or training
# set (it contains a random nonce), then ask a fresh non-interactive session a
# question only that fact answers. Two independent checks:
#   1. did the answer contain the fact?        (outcome)
#   2. did the session actually call glyph?    (mechanism)
# A pass on 1 without 2 means the agent guessed — the integration is inert.
set -uo pipefail

GLYPH="${GLYPH:-$HOME/go/bin/glyph}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
NONCE="$RANDOM$RANDOM"
SECRET="canary rollout threshold is ${NONCE} basis points"

command -v claude >/dev/null || { echo "claude CLI not on PATH"; exit 2; }
[ -x "$GLYPH" ] || { echo "glyph not executable at $GLYPH (set GLYPH=...)"; exit 2; }

cd "$WORK"
git init -q .                       # look like a real project
"$GLYPH" init >/dev/null
"$GLYPH" etch --star --type decision --tag deploy \
  --summary "Deploy: canary threshold" "We decided the $SECRET." >/dev/null
echo "seeded nonce $NONCE into $WORK/.glyph"
echo

OUT="$WORK/stream.jsonl"
claude -p "What canary rollout threshold did we decide on for deploys? Answer with the number." \
  --output-format stream-json --verbose > "$OUT" 2>"$WORK/err.txt"
RC=$?
[ $RC -ne 0 ] && { echo "claude exited $RC"; tail -3 "$WORK/err.txt"; }

ANSWER=$(python3 - "$OUT" <<'PY'
import json,sys
txt=[]
for line in open(sys.argv[1]):
    try: ev=json.loads(line)
    except ValueError: continue
    if ev.get("type")=="assistant":
        for b in ev.get("message",{}).get("content",[]):
            if b.get("type")=="text": txt.append(b["text"])
    elif ev.get("type")=="result" and ev.get("result"): txt.append(str(ev["result"]))
print(" ".join(txt))
PY
)
CALLED=$(python3 - "$OUT" <<'PY'
import json,sys
n=0
for line in open(sys.argv[1]):
    try: ev=json.loads(line)
    except ValueError: continue
    if ev.get("type")=="assistant":
        for b in ev.get("message",{}).get("content",[]):
            if b.get("type")=="tool_use":
                blob=json.dumps(b.get("input",{}))
                if "glyph" in blob or "glyph" in str(b.get("name","")): n+=1
print(n)
PY
)

echo "--- answer ---"; echo "$ANSWER" | head -5; echo
case "$ANSWER" in *"$NONCE"*) FOUND=yes ;; *) FOUND=no ;; esac
echo "fact recalled : $FOUND  (nonce $NONCE)"
echo "glyph calls   : $CALLED"
echo
if [ "$FOUND" = yes ] && [ "$CALLED" -gt 0 ]; then
  echo "PASS — the agent consulted memory and answered from it."
elif [ "$FOUND" = yes ]; then
  echo "SUSPECT — right answer, zero glyph calls. Check how it got the fact."
elif [ "$CALLED" -gt 0 ]; then
  echo "FAIL — it called glyph but did not surface the fact (retrieval/ranking)."
else
  echo "FAIL — never consulted memory. The skill is installed but inert."
fi
echo
echo "raw stream kept until exit: $OUT"
