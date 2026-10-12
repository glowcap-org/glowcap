//! Build-owned directory publication shared by installations and archives.
//! The caller assembles `stage/tree`, sets its ownership marker, then commits.
//! Handled failures restore the prior generation, SIGKILL or power loss can
//! leave it in the named staging directory. The build lease serializes writers.
const std = @import("std");

pub fn wrap(b: *std.Build, body: []const u8) []const u8 {
    return b.fmt("{s}{s}{s}", .{ begin, body, commit });
}

pub const begin =
    \\output="$1"
    \\parent=$(dirname "$output")
    \\mkdir -p "$parent"
    \\stage=$(mktemp -d "$parent/.glowcap-stage.XXXXXX")
    \\committed=false
    \\cleanup() {
    \\  stage_status=$?
    \\  trap - EXIT HUP INT TERM
    \\  if [ -d "$stage/previous" ] && [ "$committed" = false ]; then
    \\    if [ -e "$output" ] || [ -L "$output" ] || ! mv "$stage/previous" "$output"; then
    \\      echo "previous generation preserved at $stage/previous; inspect before restoring to $output" >&2
    \\      exit 1
    \\    fi
    \\  fi
    \\  rm -rf -- "$stage"
    \\  exit "$stage_status"
    \\}
    \\trap cleanup EXIT
    \\trap 'exit 129' HUP
    \\trap 'exit 130' INT
    \\trap 'exit 143' TERM
    \\mkdir "$stage/tree"
    \\
;

pub const commit =
    \\
    \\if [ -L "$output" ]; then
    \\  echo "refusing to replace symlink $output" >&2; exit 1
    \\fi
    \\if [ -e "$output" ]; then
    \\  test -d "$output" && test -f "$output/$marker" && test ! -L "$output/$marker" || {
    \\    echo "refusing to replace unowned directory $output" >&2; exit 1
    \\  }
    \\  mv "$output" "$stage/previous"
    \\fi
    \\mv "$stage/tree" "$output"
    \\committed=true
    \\
;
