#!/usr/bin/env bash
# Deterministic status/stop/health/capacity/spin for a rooms-team roster
# (nicks → /tmp/rooms-peer-<nick>).
#
# spin starts CapTP peers lead-first and emits member Task prompt blobs.
# It does NOT spawn/kill harness Tasks — lead does that per rooms-team SKILL.
set -euo pipefail

usage() {
	echo "usage: $0 status|stop|health NICK [NICK...]" >&2
	echo "       $0 capacity [ACTIVE_MEMBER_NICK...]" >&2
	echo "       $0 spin --room ROOM --locator URL --lead NICK MEMBER [MEMBER...]" >&2
	echo "       $0 speak-policy [--lead NICK]" >&2
	echo "ROOMS_TEAM_MAX_BOTS (default 4) includes the lead." >&2
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
	# Roster-filtered human room only (see rooms-peer status.human_room_pending).
	if [[ "$json" == *'"human_room_pending":true'* ]]; then
		echo "stuck_human_room"
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

speak_policy_text() {
	local lead_nick=${1:-lead}
	printf '%s\n' "Speak policy: ${lead_nick} answers human room; members answer human DMs; human @member → that member may room-reply. Multi-surface wake (human DM → human room → peer) is mandatory. Pending is per-peer — members dismiss their copy of lead-owned human room after optional content-free @${lead_nick} human-room. No bash canned replies; no ack storms."
}

write_roster() {
	local dir=$1
	shift
	mkdir -p "$dir"
	python3 - "$dir" "$@" <<'PY'
import json, sys
dir_path = sys.argv[1]
nicks = sys.argv[2:]
path = dir_path + "/roster.json"
with open(path, "w", encoding="utf-8") as f:
    json.dump({"nicks": nicks}, f, separators=(",", ":"))
    f.write("\n")
print(path)
PY
}

probe_locator() {
	local locator=$1
	case "$locator" in
	http://* | https://*)
		if command -v curl >/dev/null 2>&1; then
			if ! curl -sf --max-time 5 "$locator" >/dev/null; then
				echo "{\"ok\":false,\"error\":\"locator_unreachable\",\"detail\":$(json_escape "$locator")}" >&2
				return 1
			fi
		fi
		;;
	ocapn://*)
		# CapTP URI — rooms-peer start resolves; no HTTP probe.
		;;
	*)
		echo "{\"ok\":false,\"error\":\"locator\",\"detail\":\"expected http(s)://…/locator or ocapn://…\"}" >&2
		return 1
		;;
	esac
	return 0
}

emit_member_prompt() {
	local nick=$1
	local room=$2
	local locator=$3
	local lead_nick=$4
	local dir="/tmp/rooms-peer-${nick}"
	local out="${dir}/task-prompt.txt"
	mkdir -p "$dir"
	cat >"$out" <<EOF
Durable rooms-team member. Slug ${nick}. Nick ${nick}. DIR ${dir}.
Room ${room} (must match lead; never general). Locator ${locator}.
HUMAN PRIMACY: human leads the lead; lead leads you. human > lead > members >
strategy/persona. On redirect follow immediately.
PRESENCE: lead owns start/stop/rejoin. After human/lead stop: stay down — do NOT
wait-loop locator, auto-start, or rejoin before the lead. Rejoin only when lead
assigns it. Mid-mission peer crash with lead still present: restart same DIR ok.
DURABLE TASK (harness): You are a Task subagent, not a one-shot. Emitting a final
answer / "standing by" / "tick armed — done" COMPLETES this Task while CapTP peer
stays up and orphans the wake loop (zombie). That is harness death, not a CLI bug.
Session ends only when lead/human says stop (or lead hard-kicks).
WAKE LOOP: foreground-wait \`pancake app rooms-peer tick --dir ${dir} --wait 120\`
(block until return — do NOT background-arm then end your turn). Drain order:
(1) human channel=dm — real --dm replies in your own voice; never canned ack /
bash tick.sh; (2) human channel=room — if @you answer; else optional content-free
@${lead_nick} human-room then dismiss YOUR copy (pending is per-peer); (3) peer
chatter reply/dismiss. Then immediately tick again. DM-first is order, not
permission to ignore the room. Never dismiss --all with human lines pending.
Follow .agents/skills/rooms-peer/SKILL.md; override background-tick advice —
members foreground-wait (rooms-team SKILL). Never run rooms-peer peer.
Read rooms-team ops.md + gotchas.md. Peer chatter in the team room only.
DM PRIVACY: Reply only via --dm. Never quote/paraphrase DM content in the room.
SPEAK POLICY: $(speak_policy_text "$lead_nick")
Persona: if lead assigned a slug, load .agents/personas/<slug>.md (project lenses —
not rooms-only; other skills use them too). Stay in nick voice if no slug body.
EOF
	printf '%s\n' "$out"
}

start_peer() {
	local nick=$1
	local room=$2
	local locator=$3
	local dir="/tmp/rooms-peer-${nick}"
	mkdir -p "$dir"
	# rooms-peer start prints JSON on stdout — keep spin's stdout to one ready line.
	pancake app rooms-peer start \
		--nick "$nick" \
		--dir "$dir" \
		--room "$room" \
		--locator "$locator" >&2
}

peer_joined_registered() {
	local nick=$1
	local dir="/tmp/rooms-peer-${nick}"
	local line
	line=$(pancake app rooms-peer status --dir "$dir" 2>/dev/null || echo '{"ok":false}')
	[[ "$line" == *'"peer":"up"'* ]] || return 1
	[[ "$line" == *'"status":"joined"'* ]] || return 1
	[[ "$line" == *'"registered":true'* ]] || return 1
	return 0
}

run_spin() {
	local room="" locator="" lead=""
	local -a members=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--room)
			room=${2:-}
			shift 2
			;;
		--locator)
			locator=${2:-}
			shift 2
			;;
		--lead)
			lead=${2:-}
			shift 2
			;;
		--help | -h)
			usage
			;;
		--)
			shift
			members+=("$@")
			break
			;;
		-*)
			echo "{\"ok\":false,\"error\":\"usage\",\"detail\":\"unknown flag $1\"}" >&2
			usage
			;;
		*)
			members+=("$1")
			shift
			;;
		esac
	done
	if [[ -z "$room" || -z "$locator" || -z "$lead" ]]; then
		echo '{"ok":false,"error":"usage","detail":"spin needs --room --locator --lead and MEMBER…"}' >&2
		usage
	fi
	if [[ ${#members[@]} -eq 0 ]]; then
		echo '{"ok":false,"error":"usage","detail":"spin needs at least one MEMBER nick"}' >&2
		usage
	fi

	local max=${ROOMS_TEAM_MAX_BOTS:-4}
	local used=$((1 + ${#members[@]}))
	if [[ "$used" -gt "$max" ]]; then
		echo "{\"ok\":false,\"error\":\"over_cap\",\"detail\":\"1 lead + ${#members[@]} members > ROOMS_TEAM_MAX_BOTS=$max\"}" >&2
		exit 1
	fi

	if ! command -v pancake >/dev/null 2>&1; then
		echo "pancake not on PATH; run: zig build && export PATH=\"\$PWD/zig-out/bin:\$PATH\"" >&2
		exit 1
	fi

	probe_locator "$locator" || exit 1

	local -a roster=("$lead" "${members[@]}")
	local nick
	for nick in "${roster[@]}"; do
		write_roster "/tmp/rooms-peer-${nick}" "${roster[@]}" >/dev/null
	done

	echo "{\"ok\":true,\"phase\":\"start_lead\",\"nick\":$(json_escape "$lead"),\"room\":$(json_escape "$room")}" >&2
	if ! start_peer "$lead" "$room" "$locator"; then
		echo '{"ok":false,"error":"lead_start_failed"}' >&2
		exit 1
	fi
	if ! peer_joined_registered "$lead"; then
		echo '{"ok":false,"error":"lead_not_registered","detail":"lead start returned but not joined+registered"}' >&2
		exit 1
	fi

	local policy
	policy=$(speak_policy_text "$lead")
	local policy_file="/tmp/rooms-peer-${lead}/speak-policy.txt"
	printf '%s\n' "$policy" >"$policy_file"
	echo "{\"ok\":true,\"phase\":\"speak_policy\",\"path\":$(json_escape "$policy_file")}" >&2

	local -a prompt_paths=()
	local member
	for member in "${members[@]}"; do
		echo "{\"ok\":true,\"phase\":\"start_member\",\"nick\":$(json_escape "$member")}" >&2
		if ! start_peer "$member" "$room" "$locator"; then
			echo "{\"ok\":false,\"error\":\"member_start_failed\",\"nick\":$(json_escape "$member")}" >&2
			exit 1
		fi
		if ! peer_joined_registered "$member"; then
			echo "{\"ok\":false,\"error\":\"member_not_registered\",\"nick\":$(json_escape "$member")}" >&2
			exit 1
		fi
		prompt_paths+=("$(emit_member_prompt "$member" "$room" "$locator" "$lead")")
	done

	python3 - "$room" "$locator" "$lead" "$policy_file" "${members[@]}" -- "${prompt_paths[@]}" <<'PY'
import json, sys
args = sys.argv[1:]
sep = args.index("--")
room, locator, lead, policy_path = args[0], args[1], args[2], args[3]
members = args[4:sep]
prompts = args[sep + 1 :]
print(json.dumps({
    "ok": True,
    "phase": "ready",
    "room": room,
    "locator": locator,
    "lead": lead,
    "members": members,
    "dirs": {n: f"/tmp/rooms-peer-{n}" for n in [lead, *members]},
    "roster_leaf": "roster.json",
    "speak_policy_path": policy_path,
    "member_task_prompts": prompts,
    "hint": "Harness must spawn one durable Task per member prompt and foreground-wait tick; do not final-answer after arming. Lead posts speak_policy text in-room once.",
}, separators=(",", ":")))
PY
}

[[ $# -ge 1 ]] || usage
verb=$1
shift

export PATH="${PWD}/zig-out/bin:${PATH}"

case "$verb" in
capacity)
	max=${ROOMS_TEAM_MAX_BOTS:-4}
	if ! [[ "$max" =~ ^[1-9][0-9]*$ ]]; then
		echo "{\"ok\":false,\"error\":\"ROOMS_TEAM_MAX_BOTS must be a positive integer\"}" >&2
		exit 2
	fi
	members=$#
	used=$((1 + members))
	free=$((max - used))
	if [[ "$free" -lt 0 ]]; then
		free=0
		over=true
	else
		over=false
	fi
	printf '{"ok":true,"max":%s,"lead":1,"members":%s,"used":%s,"free":%s,"over_cap":%s,"hint":"max includes lead; pass active member nicks only"}\n' \
		"$max" "$members" "$used" "$free" "$over"
	if [[ "$used" -gt "$max" ]]; then
		exit 1
	fi
	exit 0
	;;
speak-policy)
	lead_nick=lead
	if [[ "${1:-}" == --lead ]]; then
		lead_nick=${2:-lead}
	fi
	speak_policy_text "$lead_nick"
	exit 0
	;;
spin)
	run_spin "$@"
	exit $?
	;;
status | stop | health)
	[[ $# -ge 1 ]] || usage
	;;
*)
	usage
	;;
esac

if ! command -v pancake >/dev/null 2>&1; then
	echo "pancake not on PATH; run: zig build && export PATH=\"\$PWD/zig-out/bin:\$PATH\"" >&2
	exit 1
fi

ec=0
for nick in "$@"; do
	dir="/tmp/rooms-peer-${nick}"
	if [[ ! -d "$dir" ]]; then
		echo "{\"nick\":\"${nick}\",\"dir\":\"${dir}\",\"class\":\"missing\",\"ok\":false,\"detail\":\"missing dir\"}"
		ec=1
		continue
	fi
	case "$verb" in
	status | stop)
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
