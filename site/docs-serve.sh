#!/usr/bin/env bash
# Server-lifecycle launcher for `zig build docs-serve`.
#
# Why this exists: the root build's `docs-serve` step shells out to an inner
# `zig build --build-file site/build.zig … docs-serve`, which in turn launches
# Zine's development server as a long-running grandchild. `zig build` does not
# reap that subtree when it is interrupted, so the Zine server is easily left
# orphaned — reparented to init, still bound to its port and serving stale
# content. We have repeatedly seen such orphans outlive the session.
#
# This launcher makes the teardown explicit. It runs the inner build in its own
# process group and reaps that whole group — TERM, then KILL after a short
# grace — on two triggers:
#   1. a stop signal delivered to this launcher (INT/TERM/HUP) — the terminal
#      Ctrl-C / close case, where the signal reaches every member of the
#      foreground process group, this launcher included; and
#   2. the disappearance of an ancestor build process — the "kill the build by
#      pid" / IDE-kill-terminal case, where the signal never reaches this
#      launcher, detected by a background watcher.
# It is the lifecycle detail of an existing step, not a new user command — the
# public `zig build docs-serve` is unchanged.
#
# It also keeps generated site example tabs fresh. Zine watches `site/content`
# and reloads when those pages change; CapTP transport snippets live under
# `site/examples/` and only land in the pages after `gen-site-examples`. A
# background poll regenerates when snippets (or the assembler) change, so the
# preview does not stay stale until someone remembers the gen step. Expensive
# steps such as `bench-site-report` stay opt-in.
#
# Residual limit: SIGKILL is untrappable — a SIGKILL of this launcher (or of an
# ancestor in a way that never lets the watcher run) cannot be intercepted, and
# the isolated inner group may briefly outlive it. Likewise, a bare single-pid
# SIGINT to a `zig build docs-serve` that was started as a *background* job is
# masked by the shell's job-control SIGINT handling (async jobs inherit SIGINT
# ignored) and so never reaches this subtree; an interactive terminal — Ctrl-C,
# or any foreground signal — is unaffected and tears down cleanly.
#
# Usage: docs-serve.sh <zig-exe> <build-args…>
#   e.g. docs-serve.sh /usr/local/bin/zig --build-file site/build.zig \
#          --cache-dir <cache> docs-serve [-Dport=N]
set -u

zig="${1:?usage: docs-serve.sh <zig-exe> <build-args...>}"
shift

# Zine defaults to 1990, which is also commonly held by an editor or a
# devcontainer port forward. Keep the zero-argument command useful by choosing
# the first free preview port; an explicit -Dport remains exact and fails if
# its requested port is unavailable.
has_port=false
for arg in "$@"; do
  case "${arg}" in
    -Dport=*) has_port=true ;;
  esac
done
if [ "${has_port}" = false ]; then
  port=1990
  while [ "${port}" -lt 2000 ] && (printf '' >"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; do
    port=$((port + 1))
  done
  if [ "${port}" -ge 2000 ]; then
    echo "docs-serve: no free preview port in 1990-1999" >&2
    exit 1
  fi
  echo "docs-serve: using http://127.0.0.1:${port}/" >&2
  set -- "$@" "-Dport=${port}"
fi

# Fingerprint of every input `gen-site-examples` reads. Content checksum, not
# mtime: same-second edits still register, and the poll stays dependency-free
# (no inotify/entr).
examples_stamp() {
  {
    find site/examples -type f 2>/dev/null
    printf '%s\n' tools/gen/site_examples.zig
  } | LC_ALL=C sort | while IFS= read -r path; do
    [ -f "${path}" ] || continue
    # path + bytes: renaming or editing either one invalidates the stamp
    printf '%s\0' "${path}"
    cat "${path}"
  done | cksum
}

# ui/tokens.css is the authority; site/assets/tokens.css is a symlink. Zine
# watches under site/, and a symlink target edit does not always notify, so
# nudge style.css (which @imports the tokens) when the authority changes.
ui_tokens_stamp() {
  if [ -f ui/tokens.css ]; then
    cksum <ui/tokens.css
  else
    printf 'missing\n'
  fi
}

# Keep generated tabs and shared UI tokens in step with Zine's reload loop.
# Runs in this launcher's process group (not the inner Zine group) so reap of
# the Zine subtree never kills a mid-flight `zig build gen-site-examples`.
examples_watch_loop() {
  local stamp tokens
  stamp="$(examples_stamp)"
  tokens="$(ui_tokens_stamp)"
  while true; do
    sleep 1
    local next next_tokens
    next="$(examples_stamp)"
    if [ "${next}" != "${stamp}" ]; then
      stamp="${next}"
      echo "docs-serve: site/examples changed; regenerating tabs…" >&2
      if ! "${zig}" build gen-site-examples; then
        echo "docs-serve: gen-site-examples failed (preview may be stale)" >&2
      fi
    fi
    next_tokens="$(ui_tokens_stamp)"
    if [ "${next_tokens}" != "${tokens}" ]; then
      tokens="${next_tokens}"
      echo "docs-serve: ui/tokens.css changed; nudging site CSS watch…" >&2
      touch site/assets/style.css 2>/dev/null || true
    fi
  done
}

examples_watch_loop &
examples_watcher=$!

# The inner build needs its own process group, so that the reap below can signal
# the whole subtree — the inner zig build runner and the Zine server it spawns —
# as a unit, without touching this launcher's own group and so never signalling
# the user's shell. Bash's job control does exactly that: with `set -m`, every
# job bash starts becomes a process-group leader, so the child's pid is also the
# new process-group id. That is available in any bash, which is what this script
# already requires, so it works the same on Linux and on macOS. `setsid` would
# only be available on Linux.
#
# Job control is on for the launch alone. The inner group stays in this
# launcher's session and keeps its controlling terminal, where `setsid` would
# have detached it. Nothing here wants that detachment: a terminal signal goes
# to the foreground process group, which is this launcher's and not the inner
# one, so the traps below are still what tears the server down, and a terminal
# that disappears entirely can now reach the inner group too, which only helps.
set -m
"${zig}" build "$@" &
inner_pgid=$!
set +m

reap() {
  # Stop the whole inner group: TERM first, then KILL whatever has not exited
  # after a short grace.
  kill -TERM -- "-${inner_pgid}" 2>/dev/null || true
  for _ in $(seq 1 20); do
    kill -0 -- "-${inner_pgid}" 2>/dev/null || return 0
    sleep 0.1
  done
  kill -KILL -- "-${inner_pgid}" 2>/dev/null || true
}

stop_side_watchers() {
  kill "${examples_watcher}" 2>/dev/null || true
  wait "${examples_watcher}" 2>/dev/null || true
}

# Ancestors whose exit means this preview is over: our direct parent (the inner
# build runner that `zig build` spawned) and its parent (the outer
# `zig build docs-serve` the user launched). A signal aimed only at an ancestor
# never reaches this launcher, so a watcher reaps the inner group when an
# ancestor exits.
build_runner=$PPID
outer=$(ps -o ppid= -p "$PPID" 2>/dev/null | tr -d ' ')
(
  while kill -0 "${build_runner}" 2>/dev/null \
     && { [ -z "${outer}" ] || kill -0 "${outer}" 2>/dev/null; }; do
    sleep 0.5
  done
  kill -TERM "$$" 2>/dev/null || true
) &
watcher=$!

trap 'reap; stop_side_watchers; kill "${watcher}" 2>/dev/null; trap - EXIT; exit 130' INT
trap 'reap; stop_side_watchers; kill "${watcher}" 2>/dev/null; trap - EXIT; exit 143' TERM
trap 'reap; stop_side_watchers; kill "${watcher}" 2>/dev/null; trap - EXIT; exit 129' HUP
trap 'reap; stop_side_watchers; kill "${watcher}" 2>/dev/null' EXIT

wait "${inner_pgid}"
status=$?
trap - EXIT
kill "${watcher}" 2>/dev/null || true
stop_side_watchers
reap
exit "${status}"
