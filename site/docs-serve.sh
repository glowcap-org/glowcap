#!/usr/bin/env bash
# Server-lifecycle launcher for `zig build docs-serve`.
#
# Why this exists: the root build's `docs-serve` step shells out to an inner
# `zig build … docs-serve` from `site/`, which in turn launches Zine's
# development server as a long-running grandchild. `zig build` does not
# reap that subtree when it is interrupted, so the Zine server is easily left
# orphaned: reparented to init, still bound to its port and serving stale
# content. We have repeatedly seen such orphans outlive the session.
#
# This launcher makes the teardown explicit. It runs the inner build in its own
# process group and reaps that whole group, TERM, then KILL after a short
# grace, on two triggers:
#   1. a stop signal delivered to this launcher (INT/TERM/HUP), the terminal
#      Ctrl-C / close case, where the signal reaches every member of the
#      foreground process group, this launcher included; and
#   2. the disappearance of an ancestor build process, the "kill the build by
#      pid" / IDE-kill-terminal case, where the signal never reaches this
#      launcher, detected by a background watcher.
# It is the lifecycle detail of an existing step, not a new user command, the
# public `zig build docs-serve` is unchanged.
#
# It also keeps generated site example tabs fresh. Zine watches `site/content`
# and reloads when those pages change; CapTP transport snippets live under
# `site/examples/` and only land in the pages after `gen-site-examples`. A
# background poll regenerates when snippets (or the assembler) change, so the
# preview does not stay stale until someone remembers the gen step. Expensive
# steps such as `bench-site-report` stay opt-in.
#
# Residual limit: SIGKILL is untrappable, a SIGKILL of this launcher (or of an
# ancestor in a way that never lets the watcher run) cannot be intercepted, and
# the isolated inner group may briefly outlive it. Likewise, a bare single-pid
# SIGINT to a `zig build docs-serve` that was started as a *background* job is
# masked by the shell's job-control SIGINT handling (async jobs inherit SIGINT
# ignored) and so never reaches this subtree; an interactive terminal, Ctrl-C,
# or any foreground signal, is unaffected and tears down cleanly.
#
# Usage: docs-serve.sh <zig-exe> <build-args…>
#   e.g. docs-serve.sh /usr/local/bin/zig --cache-dir <cache> \
#          --prefix <repo>/zig-out --fork <repo>/third_party/site-build/translate-c \
#          --fork <repo>/third_party/site-build/superhtml docs-serve [-Dport=N] [-Dhost=ADDR]
set -u

zig="${1:?usage: docs-serve.sh <zig-exe> <build-args...>}"
shift

# 1990 is the canonical container port Compose publishes. Stay on it unless
# `-Dport` names another; hopping to 1991 would leave the published mapping
# pointing at nothing. Loopback is the laptop default so a bare run is not a
# LAN service; the devcontainer sets `DOCS_SERVE_HOST=0.0.0.0` because a
# Docker-published port reaches only a wide bind inside the container.
has_port=false
has_host=false
for arg in "$@"; do
  case "${arg}" in
    -Dport=*) has_port=true ;;
    -Dhost=*) has_host=true ;;
  esac
done
if [ "${has_host}" = false ]; then
  set -- "$@" "-Dhost=${DOCS_SERVE_HOST:-127.0.0.1}"
fi
if [ "${has_port}" = false ]; then
  port=1990
  if (printf '' >"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
    echo "docs-serve: port ${port} is already in use; pass -Dport=N or stop the process holding it" >&2
    exit 1
  fi
  echo "docs-serve: using http://127.0.0.1:${port}/glowcap/" >&2
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
# nudge style.css (which follows the shared sheets) when the authority changes.
ui_core_stamp() {
  if [ -f ui/tokens.css ] && [ -f ui/mark.css ]; then
    cksum ui/tokens.css ui/mark.css
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
  tokens="$(ui_core_stamp)"
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
    next_tokens="$(ui_core_stamp)"
    if [ "${next_tokens}" != "${tokens}" ]; then
      tokens="${next_tokens}"
      echo "docs-serve: ui core CSS changed; nudging site CSS watch…" >&2
      touch site/assets/style.css 2>/dev/null || true
    fi
  done
}

examples_watch_loop &
examples_watcher=$!

# The inner build needs its own process group, so that the reap below can signal
# the whole subtree, the inner zig build runner and the Zine server it spawns,
# as a unit, without touching this launcher's own group and so never signalling
# the user's shell. Bash's job control does exactly that: with `set -m`, every
# job bash starts becomes a process-group leader, so the child's pid is also the
# new process-group id. Any bash has that, and this script already requires
# bash, so it works the same on Linux and on macOS. `setsid` would
# only be available on Linux.
#
# Job control is on for the launch alone. The inner group stays in this
# launcher's session and keeps its controlling terminal, where `setsid` would
# have detached it. Nothing here wants that detachment: a terminal signal goes
# to the foreground process group, which is this launcher's and not the inner
# one, so the traps below are still what tears the server down, and a terminal
# that disappears entirely can reach the inner group too, which only helps.
#
# Zine's first `docs-serve` compiles the `zine` binary. `zig build` prints
# nothing until that finishes, which looks like a hang. Say so before the
# quiet stretch, and only once: later runs are cache hits.
echo "docs-serve: compiling Zine if needed (a cold compile is silent and can take a few minutes)…" >&2
set -m
(
  cd site || exit 1
  "${zig}" build "$@"
) &
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
