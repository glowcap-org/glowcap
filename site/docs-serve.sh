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
# session/process group and reaps that whole group — TERM, then KILL after a
# short grace — on two triggers:
#   1. a stop signal delivered to this launcher (INT/TERM/HUP) — the terminal
#      Ctrl-C / close case, where the signal reaches every member of the
#      foreground process group, this launcher included; and
#   2. the disappearance of an ancestor build process — the "kill the build by
#      pid" / IDE-kill-terminal case, where the signal never reaches this
#      launcher, detected by a background watcher.
# It is the lifecycle detail of an existing step, not a new user command — the
# public `zig build docs-serve` is unchanged.
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

# setsid puts the inner build in a fresh session: it becomes its own
# process-group leader, so its pid equals the new process-group id. The inner
# zig build runner and the Zine server it spawns inherit that group, letting us
# signal the entire subtree as a unit without touching this launcher's own group
# (so we never signal the user's shell).
setsid "${zig}" build "$@" &
inner_pgid=$!

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

trap 'reap; kill "${watcher}" 2>/dev/null; trap - EXIT; exit 130' INT
trap 'reap; kill "${watcher}" 2>/dev/null; trap - EXIT; exit 143' TERM
trap 'reap; kill "${watcher}" 2>/dev/null; trap - EXIT; exit 129' HUP
trap 'reap; kill "${watcher}" 2>/dev/null' EXIT

wait "${inner_pgid}"
status=$?
trap - EXIT
kill "${watcher}" 2>/dev/null || true
reap
exit "${status}"
