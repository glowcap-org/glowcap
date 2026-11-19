//! The one browser preparation every step that drives a real headless
//! Chromium depends on.
//!
//! In the devcontainer the script prepares the checkout's exact pinned
//! browsers through the managed-tool lifecycle (`tools.sh ensure playwright`).
//! A warm run is a structural readiness check. On a host build it checks the
//! local Playwright environment instead. Preparation owns its own bounded
//! deadline, sized from the measured cold download (the shared cache makes it
//! a once-per-machine cost): a failed preparation is a setup failure, never a
//! skipped test or a longer scenario deadline.
const std = @import("std");
const commands = @import("commands.zig");

var preparations: std.AutoHashMapUnmanaged(*std.Build, *std.Build.Step) = .empty;

pub fn register(b: *std.Build) *std.Build.Step {
    const entry = preparations.getOrPut(b.allocator, b) catch @panic("OOM");
    if (entry.found_existing) return entry.value_ptr.*;

    const preflight = commands.addRootedSystemCommand(b, .build_tool, &.{
        "python3", "tools/run-with-timeout.py",           "--kill-after", "2s", "600s",
        "bash",    "tools/check/playwright-preflight.sh",
    });
    preflight.has_side_effects = true;
    entry.value_ptr.* = &preflight.step;
    return &preflight.step;
}
