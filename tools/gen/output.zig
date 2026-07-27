//! The one output descriptor every `tools/gen/` generator lists in its `outputs`
//! slice: a target path and the function that produces its bytes. Shared so a
//! generator names one type rather than redeclaring it, and the `emit.zig` /
//! `verify.zig` harness iterates one shape for every generator, single- or
//! multi-file alike.

const std = @import("std");

pub const Output = struct {
    path: []const u8,
    generate: *const fn (std.mem.Allocator) anyerror![]u8,
};
