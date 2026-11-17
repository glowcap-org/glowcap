//! Core memory retry gate seen through Loam hosting: while the Host's retry
//! deadline is armed, `advanceProgress` reports no runnable work, so a driver
//! loop parks until the deadline instead of spinning. The C export
//! `glowcap_loam_advance` forwards this result unchanged.
const std = @import("std");
const glowcap = @import("glowcap");
const f = @import("fixture.zig");

test "loam progress reports no runnable work while the core memory retry is armed" {
    const model = glowcap.ocapn.model;
    var fixture: f.Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    // Queued Host work: a dial the core owes its transport.
    _ = try fixture.host.enlivenSelectOrDial(.{
        .peer = .{ .transport = model.transport.tcp, .designator = "127.0.0.1:7095", .hints = model.Hints.emptyFalse() },
        .swissnum = "retry-gate",
    });
    try std.testing.expect(try fixture.attached.advanceProgress());
    // The runtime arms the deadline over that work. This stands in for it, and
    // the driver tests prove the runtime's own arming.
    fixture.host.memory_retry_due_ms = 1;
    try std.testing.expect(!try fixture.attached.advanceProgress());
    fixture.host.memory_retry_due_ms = null;
    try std.testing.expect(try fixture.attached.advanceProgress());
}
