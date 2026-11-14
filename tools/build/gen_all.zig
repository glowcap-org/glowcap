//! `zig build gen`: every committed mirror in one command.
//!
//! Membership comes from the graph. A `gen-<name>` step joins when its
//! `gen-<name>-check` sibling is something `check` runs, so `gen` rewrites
//! exactly what `check` verifies and a new generator joins by registering its
//! pair. A generator `check` does not verify stays a step of its own: the
//! Cap'n Proto fixtures have no check, and the mark's check needs a browser.
//!
//! Generators run in parallel unless one reads another's output. Those edges
//! are declared where the reader registers: the binding generators that read
//! generated headers, and the wasm layouts that read the layout inventory.

const std = @import("std");
const build_steps_doc = @import("build_steps_doc.zig");
const Step = std.Build.Step;

const write_prefix = "gen-";
const check_suffix = "-check";

pub fn register(b: *std.Build) void {
    const gen = b.step("gen", "Regenerate every committed mirror whose gen-*-check sibling `check` runs, in dependency order");
    const gpa = b.allocator;
    const check = b.top_level_steps.get("check") orelse @panic("`check` registers before the generator aggregate");
    var reach = std.AutoHashMap(*Step, void).init(gpa);
    build_steps_doc.collectReach(gpa, &reach, &check.step);
    for (b.top_level_steps.values()) |top| {
        const name = top.step.name;
        if (!std.mem.startsWith(u8, name, write_prefix) or std.mem.endsWith(u8, name, check_suffix)) continue;
        const sibling = b.top_level_steps.get(b.fmt("{s}{s}", .{ name, check_suffix })) orelse continue;
        if (!build_steps_doc.runs(&reach, &sibling.step)) continue;
        gen.dependOn(&top.step);
    }
}
