#!/usr/bin/env bash
# Compiled state handed from a CI build job to the test jobs of its group.
# Caller: .github/workflows/check-group.yml, on the runner host (outside the
# devcontainer), from the repository root it resolves itself.
#
#   ci/state.sh stores           print each runner-side store, one per line
#   ci/state.sh stamp            set every tracked file's mtime to HEAD's commit time
#   ci/state.sh pack <archive>   write the stores and zig-out to a zstd tar
#   ci/state.sh unpack <archive> restore them, keeping their recorded mtimes
#   ci/state.sh receive <dir> <name>...
#                                fetch this run's named artifacts into <dir>
#
# Zig keys its cache by content, but Cargo calls an output stale when a source
# is newer than it. Two jobs check the same commit out at different times, so
# both stamp the checkout to the commit time first: the build job's outputs
# are then newer than every source in the test job too. zig-out travels with
# the stores because the installer leaves an archive with unchanged bytes in
# place, and Cargo's build scripts watch those archives' mtimes.
#
# The runner is Linux, but infrastructure-check also runs this on the macOS
# host, so it keeps to bash 3.2 and to options BSD touch and tar share.
#
# Paths are absolute (tar -P), so pack and unpack must run as the same user
# with the same home and checkout path, as every hosted runner does. Exits 2
# on a malformed call, otherwise with the failing command's status. unpack
# overwrites files at the recorded paths and removes nothing.
#
# receive reads the run from the runner's GITHUB_* variables and GH_TOKEN,
# which needs actions: read. A blob transfer streams in seconds or stalls with
# no end of its own, so an attempt that moves under 1 MB/s for
# STATE_STALL_SECONDS (20) aborts and curl starts it over. A name the run
# never uploaded is skipped: the caller judges a missing archive.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

stores() {
  printf '%s\n' \
    "$HOME/.cache/glowcap/tool/zig" \
    "$HOME/.cache/glowcap/ci/zig-local" \
    "$HOME/.cache/glowcap/ci/cargo-build" \
    "$HOME/.cache/glowcap/tool/deno/gen" \
    "$HOME/.cache/glowcap/tool/deno/check_cache_v2" \
    "$HOME/.cache/glowcap/tool/deno/dep_analysis_cache_v2" \
    "$HOME/.cache/glowcap/tool/deno/v8_code_cache_v2"
}

usage() {
  echo "usage: ci/state.sh stores | stamp | pack <archive> | unpack <archive> | receive <dir> <name>..." >&2
  exit 2
}

# curl strips the Authorization header when the artifact redirects to its blob.
api() {
  curl -fsSL --retry 4 --retry-connrefused --connect-timeout 10 \
    --speed-limit 1048576 --speed-time "${STATE_STALL_SECONDS:-20}" \
    -H "Authorization: Bearer $GH_TOKEN" -H 'Accept: application/vnd.github+json' "$@"
}

case "${1:-}" in
  stores)
    [ "$#" -eq 1 ] || usage
    stores
    ;;
  stamp)
    [ "$#" -eq 1 ] || usage
    # touch -t in UTC is the form GNU and BSD touch share.
    when=$(TZ=UTC0 git -C "$root" log -1 --date=format-local:%Y%m%d%H%M.%S --format=%cd HEAD)
    # -c never creates a file the index names but the checkout lacks.
    git -C "$root" ls-files -z --recurse-submodules |
      (cd "$root" && TZ=UTC0 xargs -0 touch -c -h -t "$when" --)
    ;;
  pack)
    [ "$#" -eq 2 ] || usage
    paths=()
    while IFS= read -r store; do
      [ -e "$store" ] && paths+=("$store")
    done < <(stores)
    [ -e "$root/zig-out" ] && paths+=("$root/zig-out")
    [ "${#paths[@]}" -gt 0 ] || { echo "ci/state.sh: nothing to pack" >&2; exit 1; }
    du -sh "${paths[@]}"
    tar -P --use-compress-program='zstd -T0 -3' -cf "$2" "${paths[@]}"
    ls -l "$2"
    ;;
  unpack)
    [ "$#" -eq 2 ] || usage
    tar -P --use-compress-program='zstd -d -T0' -xf "$2"
    ;;
  receive)
    [ "$#" -ge 3 ] || usage
    dir=$2
    shift 2
    actions="$GITHUB_API_URL/repos/$GITHUB_REPOSITORY/actions"
    mkdir -p "$dir"
    for name in "$@"; do
      id=$(api "$actions/runs/$GITHUB_RUN_ID/artifacts?name=$name" |
        jq -r '[.artifacts[] | select(.expired | not)] | last | .id // empty')
      if [ -z "$id" ]; then
        echo "ci/state.sh: run $GITHUB_RUN_ID has no artifact $name"
        continue
      fi
      api -o "$dir/$name.zip" "$actions/artifacts/$id/zip"
      unzip -o -q "$dir/$name.zip" -d "$dir"
      rm -f -- "$dir/$name.zip"
    done
    ;;
  *) usage ;;
esac
