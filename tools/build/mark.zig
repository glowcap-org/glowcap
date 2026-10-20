//! The still mark, generated from the shader that draws the live one.
//!
//! The mushroom has one authority, `apps/rooms/web/ui/mark/field.ts`, and
//! everything still is traced out of a render of it: the artwork under
//! `site/assets/`, the favicon and the square icon cut from the same trace,
//! the lit reading the README carries, and the masks, line drawing, tones,
//! and placement the browser UI paints through in `ui/`. `tools/gen/mark/` is
//! the generator, and its own header carries the method.
//!
//! Both steps drive the pinned headless Chromium, because running the shader
//! means running a browser with a GPU adapter. That makes them browser proofs
//! and therefore siblings of `check` rather than members of it, like every
//! other browser proof in this build. What does ride `check` is the cheaper
//! half `zig build source-check` owns: the committed files carry one geometry
//! between them, so a hand edit to any one of them is caught in-tree even
//! though the render is not available there.

const std = @import("std");
const execution = @import("execution.zig");

pub fn register(b: *std.Build, browser_preflight: *std.Build.Step) void {
    const write = execution.addSystemCommand(b, .{ .browser_proof = 300 }, &.{
        "deno", "run", "--allow-all", "tools/gen/mark/main.ts", "write",
    });
    write.setCwd(b.path("."));
    write.has_side_effects = true;
    write.step.dependOn(browser_preflight);
    const write_step = b.step("gen-mark", "Re-trace the still mark from the shader and rewrite the unlit and lit artwork under site/assets/ with their rasters, plus the mark's generated blocks in ui/ (needs deno + the image-baked browser)");
    write_step.dependOn(&write.step);

    const check = execution.addSystemCommand(b, .{ .browser_proof = 300 }, &.{
        "deno", "run", "--allow-all", "tools/gen/mark/main.ts", "check",
    });
    check.setCwd(b.path("."));
    check.has_side_effects = true;
    check.step.dependOn(browser_preflight);
    const check_step = b.step("gen-mark-check", "Verify the committed still mark still matches a fresh trace of the shader (fails if stale)");
    check_step.dependOn(&check.step);
}
