//! Run `zig build bench-host-locator` to measure requested allocation traffic
//! in warmed Host route replacement and repeated accept fallback. Host setup
//! and catalog growth are outside the window. No network or sessions are opened.
const std = @import("std");
const glowcap = @import("glowcap");
const Host = glowcap.driver.core.Host;
const model = glowcap.ocapn.model;
const turns = 1024;
const Operation = enum { select, retain, accept };
const hints = [_]model.HintEntry{
    .{ .name = "route-a", .value = .{ .string = "one" } },
    .{ .name = "route-b", .value = .{ .string = "two" } },
    .{ .name = "route-c", .value = .{ .string = "three" } },
    .{ .name = "route-d", .value = .{ .string = "four" } },
};

fn apply(host: *Host, operation: Operation, candidate: model.PeerLocator) !void {
    switch (operation) {
        .select => try host.setAdvertisedLocator(candidate),
        .retain => try host.retainAdvertisedLocator(candidate),
        .accept => try host.ensureAcceptAdvertisedLocator(.address, candidate.designator, candidate.designator, candidate.transport),
    }
}
fn measure(operation: Operation, carried: []const model.HintEntry) !void {
    var traffic = std.testing.FailingAllocator.init(std.heap.smp_allocator, .{});
    var options: Host.Options = .{};
    options.captp_version = .next;
    options.codec = .capnp;
    // Fixed independent seeds suffice: this benchmark never serves a session.
    var host = try Host.init(traffic.allocator(), @splat(0x82), @splat(0x83), options);
    defer host.deinit();
    const candidate: model.PeerLocator = .{ .transport = "tcp", .designator = "127.0.0.1:7088", .hints = .{ .entries = carried } };
    for (0..8) |_| try apply(&host, operation, candidate);
    const count = traffic.alloc_index;
    const bytes = traffic.allocated_bytes;
    for (0..turns) |_| try apply(&host, operation, candidate);
    std.debug.print("host_locator operation={s} carried={d} turns={d} allocations_per_turn={d} requested_bytes_per_turn={d}\n", .{
        @tagName(operation),                   carried.len,                               turns,
        (traffic.alloc_index - count) / turns, (traffic.allocated_bytes - bytes) / turns,
    });
}
pub fn main() !void {
    for ([_]Operation{ .select, .retain }) |operation| {
        try measure(operation, &.{});
        try measure(operation, &hints);
    }
    try measure(.accept, &.{});
}
