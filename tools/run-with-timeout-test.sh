#!/usr/bin/env bash
# Black-box test for tools/run-with-timeout.py.
#
# The wrapper bounds every gate in ci/gates.sh, and ci/gates.sh branches on the
# codes it returns, so the contract is its observable behaviour: the exit code
# a shell sees, the signal the child actually receives, and whether anything
# survives the wrapper. A source-string check cannot see any of that.
set -eu

cd "$(dirname "${BASH_SOURCE[0]}")/.."
RWT="tools/run-with-timeout.py"
fail=0
scratch=$(mktemp -d)
wrapper=
cleanup() {
	if [ -n "$wrapper" ]; then
		kill -TERM "$wrapper" 2>/dev/null || true
		wait "$wrapper" 2>/dev/null || true
	fi
	rm -rf -- "$scratch"
}
trap cleanup EXIT
ok() { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1" >&2; fail=1; }

expect_code() {
	local want=$1 label=$2
	shift 2
	local got=0
	"$@" >/dev/null 2>&1 || got=$?
	if [ "$got" -eq "$want" ]; then ok "$label ($want)"; else bad "$label: want $want, got $got"; fi
}

expect_code 0 "clean exit" python3 "$RWT" 5s true
expect_code 3 "child exit code passes through" python3 "$RWT" 5s sh -c 'exit 3'
expect_code 137 "signal death reports 128+N" python3 "$RWT" 5s sh -c 'kill -9 $$'
# An absolute path, not a bare name: a PATH search can report EACCES from an
# unreadable PATH component and turn "no such command" into 126.
expect_code 127 "missing command" python3 "$RWT" 5s "$scratch/definitely-not-a-command"
printf 'x' >"$scratch/noexec" && chmod 644 "$scratch/noexec"
expect_code 126 "not executable" python3 "$RWT" 5s "$scratch/noexec"
expect_code 2 "infinite deadline is invalid" python3 "$RWT" inf true
expect_code 2 "not-a-number deadline is invalid" python3 "$RWT" nan true
expect_code 124 "deadline fires" python3 "$RWT" --kill-after 1s 1s sh -c 'sleep 30'
expect_code 124 "a child ignoring SIGTERM is still bounded" \
	python3 "$RWT" --kill-after 1s 1s sh -c 'trap "" TERM; sleep 30'

quiet_output=$(python3 "$RWT" --quiet-success 5s sh -c 'echo hidden-out; echo hidden-error >&2' 2>&1)
if [ -z "$quiet_output" ]; then
	ok "quiet success suppresses child output"
else
	bad "quiet success leaked child output: $quiet_output"
fi
quiet_failure="$scratch/quiet-failure"
quiet_code=0
python3 "$RWT" --quiet-success 5s sh -c 'echo replayed-out; echo replayed-error >&2; exit 9' >"$quiet_failure" 2>&1 || quiet_code=$?
if [ "$quiet_code" -eq 9 ] && grep -q replayed-out "$quiet_failure" && grep -q replayed-error "$quiet_failure"; then
	ok "quiet failure replays combined child output"
else
	bad "quiet failure lost output or exit status (got $quiet_code)"
fi
# The child must receive the signal that arrived, not a substitute. A child
# that exits 42 only on SIGINT proves the relay preserved it.
# A Python victim records the signal number it actually received. A `sh` trap
# is not a reliable observer here: it may not run its handler before the shell
# dies with the signal that reached its own foreground child.
saw="$scratch/signal"
victim="$scratch/victim.py"
cat >"$victim" <<VICTIM
import signal, sys, time
def seen(sig, _frame):
    open("$saw", "w").write(str(sig))
    sys.exit(42)
signal.signal(signal.SIGINT, seen)
time.sleep(10)
VICTIM
python3 "$RWT" 20s python3 "$victim" &
wrapper=$!
sleep 1
kill -INT "$wrapper" 2>/dev/null || true
wait "$wrapper" 2>/dev/null || true
wrapper=
if [ "$(cat "$saw" 2>/dev/null || echo none)" = "2" ]; then
	ok "the child receives the signal that arrived, not a substitute"
else
	bad "child did not receive SIGINT (got: $(cat "$saw" 2>/dev/null || echo nothing))"
fi
# Nothing may outlive the wrapper. The child writes its pid, then sleeps past
# the deadline; after the wrapper returns, that pid must be gone.
pidfile="$scratch/pid"
python3 "$RWT" --kill-after 1s 1s sh -c 'echo $$ >'"$pidfile"'; sleep 30' >/dev/null 2>&1 || true
child=$(cat "$pidfile" 2>/dev/null || echo "")
if [ -z "$child" ]; then
	bad "child never recorded its pid"
elif kill -0 "$child" 2>/dev/null; then
	bad "child $child outlived the wrapper"
	kill -9 "$child" 2>/dev/null || true
else
	ok "no child outlives the wrapper"
fi

# The other half of the contract: the sequence that reads these codes must
# actually classify them. Sourced, so this exercises the real function rather
# than looking for its text — a literal can survive in a branch nobody takes.
# shellcheck disable=SC1091
GATES_SOURCE_ONLY=1 . ci/gates.sh
for code in 124 137; do
	if wedged_rc "$code"; then ok "ci/gates.sh classifies $code as wedged"; else bad "ci/gates.sh does not classify $code as wedged"; fi
done
for code in 0 1 2 126 127 143; do
	if wedged_rc "$code"; then bad "ci/gates.sh misclassifies $code as wedged"; fi
done
ok "ci/gates.sh leaves ordinary failures unclassified"

# CI owns the same per-test timeout as the devcontainer front. Exercise its
# argv rewrite with a fake Zig so a later explicit override cannot become two
# conflicting flags.
fake_bin="$scratch/bin"
fake_args="$scratch/zig-args"
mkdir -p "$fake_bin"
cat >"$fake_bin/zig" <<'FAKE_ZIG'
#!/bin/sh
printf '%s\n' "$@" >"$GLOWCAP_TEST_ZIG_ARGS"
FAKE_ZIG
chmod +x "$fake_bin/zig"
GLOWCAP_TEST_ZIG_ARGS="$fake_args" PATH="$fake_bin:$PATH" GATE_TIMEOUT=5s gate zig build test
if [ "$(grep -c -- '--test-timeout' "$fake_args")" -eq 1 ] && grep -qx 30s "$fake_args"; then
	ok "ci adds one default per-test timeout"
else
	bad "ci did not add exactly one default per-test timeout"
fi
GLOWCAP_TEST_ZIG_ARGS="$fake_args" PATH="$fake_bin:$PATH" GATE_TIMEOUT=5s gate zig build test --test-timeout 7s
if [ "$(grep -c -- '--test-timeout' "$fake_args")" -eq 1 ] && grep -qx 7s "$fake_args" && ! grep -qx 30s "$fake_args"; then
	ok "ci preserves one explicit per-test timeout"
else
	bad "ci duplicated or replaced the explicit per-test timeout"
fi
if [ "$fail" -ne 0 ]; then
	echo "run-with-timeout-test: FAILED" >&2
	exit 1
fi
echo "run-with-timeout-test: ok"
