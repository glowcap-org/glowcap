//! Language projections of the shared failure metadata contract.
const std = @import("std");
const Buffer = std.ArrayList(u8);

pub fn rust(out: *Buffer, allocator: std.mem.Allocator) !void {
    try @import("break_cause_rust.zig").generate(out, allocator);
}
pub fn python(out: *Buffer, allocator: std.mem.Allocator) !void {
    try @import("break_cause_python.zig").generate(out, allocator);
}
pub fn racket(out: *Buffer, allocator: std.mem.Allocator) !void {
    try @import("break_cause_racket.zig").generate(out, allocator);
}
pub fn typescript(out: *Buffer, allocator: std.mem.Allocator) !void {
    try @import("break_cause_ts.zig").generate(out, allocator);
}
