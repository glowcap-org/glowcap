#!/usr/bin/env bash
# Deterministic status/stop/health for a rooms-team roster (nicks → /tmp/rooms-peer-<nick>).
# Does not start CapTP peers or arm ticks — each agent runs rooms-peer for that.
set -euo pipefail

usage() {
	echo "usage: $0 status|stop|health NICK [NICK...]" >&2
	exit 2
}

classify() {
	local json=$1
	if [[ "$json" == *'"detail":"missing dir"'* ]]; then
		echo "missing"
		return
	fi
	if [[ "$json" == *'"peer":"down"'* ]] || [[ "$json" == *'"ok":false'* && "$json" != *'"peer":"up"'* ]]; then
		echo "down"
		return
	fi
	if [[ "$json" != *'"peer":"up"'* ]]; then
		echo "down"
		return
	fi
	local pending
	pending=$(printf '%s' "$json" | sed -n 's/.*"pending"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)
	pending=${pending:-0}
	if [[ "$pending" -gt 0 ]]; then
		echo "busy"
	else
		echo "idle"
	fi
}

json_escape() {
	printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()), end="")' 2>/dev/null ||
		printf '"%s"' "${1//\"/\\\"}"
}

[[ $# -ge 2 ]] || usage
verb=$1
shift

export PATH="${PWD}/zig-out/bin:${PATH}"
if ! command -v pancake >/dev/null 2>&1; then
	echo "pancake not on PATH; run: zig build && export PATH=\"\$PWD/zig-out/bin:\$PATH\"" >&2
	exit 1
fi

case "$verb" in
status|stop|health) ;;
*) usage ;;
esac

ec=0
for nick in "$@"; do
	dir="/tmp/rooms-peer-${nick}"
	if [[ ! -d "$dir" ]]; then
		echo "{\"nick\":\"${nick}\",\"dir\":\"${dir}\",\"class\":\"missing\",\"ok\":false,\"detail\":\"missing dir\"}"
		ec=1
		continue
	fi
	case "$verb" in
	status|stop)
		pancake app rooms-peer "$verb" --dir "$dir" || ec=1
		;;
	health)
		line=$(pancake app rooms-peer status --dir "$dir" 2>/dev/null || echo '{"ok":false,"peer":"down"}')
		class=$(classify "$line")
		raw=$(json_escape "$line")
		echo "{\"nick\":\"${nick}\",\"dir\":\"${dir}\",\"class\":\"${class}\",\"status\":${raw}}"
		if [[ "$class" == "down" || "$class" == "missing" ]]; then
			ec=1
		fi
		;;
	esac
done
exit "$ec"
