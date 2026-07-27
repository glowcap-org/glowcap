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
expect_code 127 "missing command" python3 "$RWT" 5s "${TMPDIR:-/tmp}/definitely-not-a-command.$$"
printf 'x' >"${TMPDIR:-/tmp}/rwt-noexec.$$" && chmod 644 "${TMPDIR:-/tmp}/rwt-noexec.$$"
expect_code 126 "not executable" python3 "$RWT" 5s "${TMPDIR:-/tmp}/rwt-noexec.$$"
rm -f "${TMPDIR:-/tmp}/rwt-noexec.$$"
expect_code 124 "deadline fires" python3 "$RWT" --kill-after 1s 1s sh -c 'sleep 30'
expect_code 124 "a child ignoring SIGTERM is still bounded" \
	python3 "$RWT" --kill-after 1s 1s sh -c 'trap "" TERM; sleep 30'

# The child must receive the signal that arrived, not a substitute. A child
# that exits 42 only on SIGINT proves the relay preserved it.
# A Python victim records the signal number it actually received. A `sh` trap
# is not a reliable observer here: it may not run its handler before the shell
# dies with the signal that reached its own foreground child.
saw="${TMPDIR:-/tmp}/rwt-signal.$$"
victim="${TMPDIR:-/tmp}/rwt-victim.$$.py"
rm -f "$saw"
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
rm -f "$victim"
if [ "$(cat "$saw" 2>/dev/null || echo none)" = "2" ]; then
	ok "the child receives the signal that arrived, not a substitute"
else
	bad "child did not receive SIGINT (got: $(cat "$saw" 2>/dev/null || echo nothing))"
fi
rm -f "$saw"

# Nothing may outlive the wrapper. The child writes its pid, then sleeps past
# the deadline; after the wrapper returns, that pid must be gone.
pidfile="${TMPDIR:-/tmp}/rwt-pid.$$"
rm -f "$pidfile"
python3 "$RWT" --kill-after 1s 1s sh -c 'echo $$ >'"$pidfile"'; sleep 30' >/dev/null 2>&1 || true
child=$(cat "$pidfile" 2>/dev/null || echo "")
rm -f "$pidfile"
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

if [ "$fail" -ne 0 ]; then
	echo "run-with-timeout-test: FAILED" >&2
	exit 1
fi
echo "run-with-timeout-test: ok"
