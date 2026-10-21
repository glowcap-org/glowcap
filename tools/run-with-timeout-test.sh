#!/usr/bin/env bash
# Black-box test for tools/run-with-timeout.py.
#
# The wrapper bounds every gate in ci/gates.sh, and ci/gates.sh branches on the
# codes it returns, so the contract is its observable behaviour: the exit code
# a shell sees, the signal the child receives, and whether anything
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

deadline_said=$(python3 "$RWT" --kill-after 1s 1s sh -c 'sleep 30' 2>&1 >/dev/null || true)
case "$deadline_said" in
*"1s deadline"*) ok "a fired deadline names itself on stderr" ;;
*) bad "a fired deadline was silent (got: $deadline_said)" ;;
esac

heartbeat_output="$scratch/heartbeat"
heartbeat_rc=0
python3 "$RWT" --heartbeat 0.02s --kill-after 0.1s 0.15s sh -c 'sleep 30' >"$heartbeat_output" 2>&1 || heartbeat_rc=$?
if [ "$heartbeat_rc" -eq 124 ] && grep -q 'still running' "$heartbeat_output" && grep -q 'deadline and was stopped' "$heartbeat_output"; then
	ok "heartbeat reports activity without extending the deadline"
else
	bad "heartbeat lost progress or deadline status (got $heartbeat_rc)"
fi
expect_code 3 "heartbeat preserves child failure" python3 "$RWT" --heartbeat 0.01s 5s sh -c 'sleep 0.05; exit 3'

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

# A leader exiting on TERM must not hide a descendant that ignores it.
# Exercise both deadline expiry and external cancellation against that group.
if python3 - "$RWT" "$scratch" <<'PYTEST'
import os, pathlib, signal, subprocess, sys, time

for mode in ("deadline", "cancel"):
    marker = pathlib.Path(sys.argv[2]) / ("descendant-" + mode)
    child = (
        "import os,pathlib,signal,time; "
        "signal.signal(signal.SIGTERM,signal.SIG_IGN); "
        f"marker=pathlib.Path({str(marker)!r}); "
        "marker.with_suffix('.ready').write_text(str(os.getpid())); "
        "marker.with_suffix('.ready').replace(marker); time.sleep(30)"
    )
    parent = f"import subprocess,sys,time; subprocess.Popen([sys.executable,'-c',{child!r}]); time.sleep(30)"
    wrapper = subprocess.Popen(
        [sys.executable, sys.argv[1], "--kill-after", "0.2s",
         "2s" if mode == "deadline" else "20s", sys.executable, "-c", parent],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    descendant = None
    try:
        ready = time.monotonic() + 5
        while not marker.exists() and time.monotonic() < ready:
            time.sleep(0.01)
        descendant = int(marker.read_text())
        if mode == "cancel":
            wrapper.send_signal(signal.SIGTERM)
        assert wrapper.wait(timeout=5) == (124 if mode == "deadline" else 143)
        # An orphan is reaped by init, so allow that observation to catch up.
        reaped = time.monotonic() + 2
        while True:
            try:
                os.kill(descendant, 0)
            except ProcessLookupError:
                break
            assert time.monotonic() < reaped, f"descendant survived {mode}"
            time.sleep(0.01)
    finally:
        if wrapper.poll() is None:
            wrapper.kill()
            wrapper.wait()
        if descendant is not None:
            try:
                os.kill(descendant, signal.SIGKILL)
            except ProcessLookupError:
                pass
PYTEST
then
	ok "deadline and cancellation stop descendants after their leader exits"
else
	bad "a descendant outlived its terminated process group"
fi

# The other half of the contract: the sequence that reads these codes must
# actually classify them. Sourced, so this exercises the real function rather
# than looking for its text, a literal can survive in a branch nobody takes.
EVIDENCE_ROWS="$scratch/gates.tsv"
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
sleep "${GLOWCAP_TEST_DELAY:-0}"
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
# Only the cold aggregate build gets its longer budget; ordinary gates keep
# theirs. Both still receive the same per-test deadline above.
GLOWCAP_TEST_ZIG_ARGS="$fake_args" GLOWCAP_TEST_DELAY=0.2 PATH="$fake_bin:$PATH" GATE_TIMEOUT=0.1s CHECK_TIMEOUT=2s gate zig build check
ok "ci gives the cold check its separate build allowance"
ordinary_rc=0
(GLOWCAP_TEST_ZIG_ARGS="$fake_args" GLOWCAP_TEST_DELAY=0.2 PATH="$fake_bin:$PATH" GATE_TIMEOUT=0.1s CHECK_TIMEOUT=2s gate zig build test) >/dev/null 2>&1 || ordinary_rc=$?
if [ "$ordinary_rc" -eq 124 ]; then
	ok "ci retains the ordinary gate deadline"
else
	bad "ci widened the ordinary gate deadline (got $ordinary_rc)"
fi
if [ "$(wc -l < "$EVIDENCE_ROWS" | tr -d ' ')" -eq 4 ]; then
	ok "ci records all exercised gates"
else
	bad "ci did not record all exercised gates"
fi
if [ "$fail" -ne 0 ]; then
	echo "run-with-timeout-test: FAILED" >&2
	exit 1
fi
echo "run-with-timeout-test: ok"
