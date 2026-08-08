#!/usr/bin/env bash
# Lead wake pager for rooms-team (operator session, not a member Task).
#
# Blocks on `rooms-peer tick --json` and prints AGENT_LOOP_WAKE_lead_pending
# when a non-roster author has channel=dm|room pending. Pair with harness
# notify_on_output on that sentinel.
#
# tick defaults to --plain; a JSON pager without --json never wakes.
set -euo pipefail

usage() {
	echo "usage: $0 HARNESS_DIR [ROSTER_NICK...]" >&2
	echo "  ROSTER_NICK defaults: agentic-lead engineering-steward fresh-eyes" >&2
	exit 2
}

[[ $# -ge 1 ]] || usage

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# Prefer git toplevel from the skill tree; fall back to walking to repo root.
if REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null); then
	:
else
	REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../../.." && pwd)
fi
export PATH="$REPO_ROOT/zig-out/bin:${PATH:-}"

DIR=$1
shift
if [[ $# -gt 0 ]]; then
	ROSTER=("$@")
else
	ROSTER=(agentic-lead engineering-steward fresh-eyes)
fi

command -v pancake >/dev/null || {
	echo "lead-watch: pancake not on PATH (build + export zig-out/bin)" >&2
	exit 1
}
command -v python3 >/dev/null || {
	echo "lead-watch: python3 required" >&2
	exit 1
}

MEMBERS_JSON=$(printf '%s\n' "${ROSTER[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')
FP_FILE=$DIR/lead-watch.fp
ERR_FILE=$DIR/lead-watch.err
LAST_TICK=$DIR/last-tick.json
HUMAN_FILE=$DIR/HUMAN_PENDING
LAST_FP=

cd "$REPO_ROOT"

emit_wake() {
	local last_fp=$1
	MEMBERS_JSON=$MEMBERS_JSON DIR=$DIR LAST_FP=$last_fp \
		LAST_TICK=$LAST_TICK HUMAN_FILE=$HUMAN_FILE FP_FILE=$FP_FILE ERR_FILE=$ERR_FILE \
		python3 - <<'PY'
import hashlib, json, os, sys, time

dir_ = os.environ["DIR"]
members = set(json.loads(os.environ["MEMBERS_JSON"]))
last_fp = os.environ.get("LAST_FP") or ""
last_tick = os.environ["LAST_TICK"]
human_file = os.environ["HUMAN_FILE"]
fp_file = os.environ["FP_FILE"]
err_file = os.environ["ERR_FILE"]

try:
    payload = json.load(open(last_tick))
except Exception as exc:
    open(err_file, "a").write(f"parse: {exc}\n")
    open(fp_file, "w").write("")
    sys.exit(0)

human = []
for item in payload.get("pending") or []:
    author = item.get("author") or item.get("peer") or ""
    if not author or author in members:
        continue
    channel = item.get("channel")
    if channel not in ("dm", "room"):
        continue
    human.append(
        {
            "channel": channel,
            "author": author,
            "id": item.get("id"),
            "text": (item.get("text") or "")[:160],
        }
    )

if not human:
    open(fp_file, "w").write("")
    sys.exit(0)

open(human_file, "w").write(json.dumps({"n": len(human), "pending": human}) + "\n")
ids = ",".join(sorted(h["id"] for h in human if h.get("id")))
fp = hashlib.sha256(ids.encode()).hexdigest()[:16]
open(fp_file, "w").write(fp)

if fp == last_fp:
    # Same human set still pending — do not spam the harness.
    time.sleep(15)
    sys.exit(0)

print(
    "AGENT_LOOP_WAKE_lead_pending "
    + json.dumps(
        {
            "n": len(human),
            "channels": sorted({h["channel"] for h in human}),
        }
    ),
    flush=True,
)
# Brief pause so the operator session can drain before the next tick.
time.sleep(5)
PY
}

while true; do
	# Capture even on non-zero; a dead peer must not kill the pager loop.
	set +e
	OUT=$(pancake app rooms-peer tick --dir "$DIR" --wait 120 --json 2>&1)
	set -e
	printf '%s\n' "$OUT" >|"$LAST_TICK"
	emit_wake "$LAST_FP"
	LAST_FP=$(cat "$FP_FILE" 2>/dev/null || true)
done
