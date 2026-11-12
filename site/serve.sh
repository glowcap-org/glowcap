#!/usr/bin/env bash
# Runs the site's development server for `zig build site-serve` and tears it
# down with the step.
#
# The root step runs an inner `zig build site-serve` from `site/`, which starts
# Zine's development server as a long-running grandchild. This launcher runs
# that inner build in its own process group and stops the whole group (TERM,
# then KILL after a short grace) when either of two things happens:
#   1. this launcher receives INT, TERM, or HUP, as on Ctrl-C or a closed
#      terminal, or
#   2. an ancestor build process exits without signaling it, as when the build
#      is killed by pid, which a background watcher notices.
#
# It also keeps the generated example tabs current. Zine reloads when
# `site/content` changes, but the CapTP snippets under `site/examples/` reach
# the pages only through `gen-site-examples`, so a background poll reruns it
# when a snippet or the assembler changes. Expensive steps such as
# `bench-site-report` stay opt-in.
#
# Limits: SIGKILL cannot be trapped, so after a SIGKILL of this launcher the
# inner group may briefly outlive it. A single-pid SIGINT to a `site-serve`
# started as a background job never arrives, because the shell starts
# background jobs with SIGINT ignored. A foreground Ctrl-C tears down cleanly.
#
# Usage: serve.sh <zig-exe> <build-args…>
#   e.g. serve.sh /usr/local/bin/zig --cache-dir <cache> \
#          --prefix <repo>/zig-out site-serve [-Dport=N] [-Dhost=ADDR]
set -u

zig="${1:?usage: serve.sh <zig-exe> <build-args...>}"
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
    echo "site-serve: port ${port} is already in use; pass -Dport=N or stop the process holding it" >&2
    exit 1
  fi
  echo "site-serve: preview will use http://127.0.0.1:${port}/glowcap/ after preparation" >&2
  set -- "$@" "-Dport=${port}"
fi

# Keep the build graph identical on clean and warm checkouts. The preview
# owns this runtime cache decision, while a site build always captures and
# exports afresh. Zine refuses a listed static directory that is missing, so
# the Rooms page must exist before the server starts.
needed=""
compgen -G 'site/assets/rooms-*.webp' >/dev/null || needed="${needed} site-captures"
[ -f site/assets/rooms/app/index.html ] || needed="${needed} site-rooms-page"
if [ -n "${needed}" ]; then
  echo "site-serve: Rooms pictures or page not cached; building Rooms and preparing them before serving. A cold build can take several minutes." >&2
  started=$SECONDS
  # shellcheck disable=SC2086
  "${zig}" build ${needed} || exit $?
  echo "site-serve: Rooms assets prepared in $((SECONDS - started))s; starting the site build" >&2
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
      echo "site-serve: site/examples changed; regenerating tabs…" >&2
      if ! "${zig}" build gen-site-examples; then
        echo "site-serve: gen-site-examples failed (preview may be stale)" >&2
      fi
    fi
    next_tokens="$(ui_core_stamp)"
    if [ "${next_tokens}" != "${tokens}" ]; then
      tokens="${next_tokens}"
      echo "site-serve: ui core CSS changed; nudging site CSS watch…" >&2
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
# Zine's first `site-serve` compiles the `zine` binary. `zig build` prints
# nothing until that finishes, which looks like a hang. Say so before the
# quiet stretch, and only once: later runs are cache hits.
echo "site-serve: compiling Zine if needed (a cold compile is silent and can take a few minutes)…" >&2
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
# `zig build site-serve` the user launched). A signal aimed only at an ancestor
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
