//! A live Goblins object is retained by two application handles, survives the
//! first release, and is reclaimed after the last release with the session open.

const std = @import("std");
const glowcap = @import("glowcap");
const harness = @import("interop_harness");
const driver = glowcap.driver;
const tcp = glowcap.net.tcp;

pub fn prove(io: std.Io, allocator: std.mem.Allocator, port: u16) !void {
    var resident = tcp.Resident{ .io = io };
    var locator_buf: [tcp.designator_buf_len]u8 = undefined;
    const address = try tcp.parseHostPort("127.0.0.1", port);
    var session = try driver.connect(allocator, &.{resident.netlayer()}, tcp.locatorFromAddress(&locator_buf, address), .ephemeral, .{
        .handshake = .{ .ms = 5_000 },
        .settle = .{ .ms = 5_000 },
    });
    defer session.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const probe = try session.fetch("glowcapGcProbeSwissnumABCDEF1234");
    const made = try fulfilled(try session.call(probe, "make", &.{}, arena));
    if (made != .list or made.list.len != 2 or made.list[0] != .capability or made.list[1] != .capability)
        return error.WrongGcProbeReply;
    const first = made.list[0].capability;
    const second = made.list[1].capability;
    try session.release(first);
    const greeting = try fulfilled(try session.call(second, "read", &.{}, arena));
    if (greeting != .string or !std.mem.eql(u8, greeting.string, "still held"))
        return error.ReleasedAnotherHandle;
    const held = try fulfilled(try session.call(probe, "collected?", &.{}, arena));
    if (held != .boolean or held.boolean) return error.CollectedHeldCapability;
    try session.release(second);

    const deadline = harness.deadlineAfter(io, 5_000);
    while (!harness.expired(io, deadline)) {
        const collected = try fulfilled(try session.call(probe, "collected?", &.{}, arena));
        if (collected != .boolean) return error.WrongGcProbeReply;
        if (collected.boolean) {
            try session.release(probe);
            try session.close(.{ .finish = .{ .ms = 5_000 } });
            std.debug.print("goblins-gc: owning Session releases exports and answers; Goblins reclaimed the object before session close\n", .{});
            return;
        }
        _ = arena_state.reset(.retain_capacity);
    }
    return error.GoblinsObjectNotReclaimed;
}

fn fulfilled(reply: driver.Reply) !driver.Value {
    return switch (reply) {
        .fulfilled => |value| value,
        .broken => error.GcProbeCallBroke,
    };
}
