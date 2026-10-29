//! The Host C ABI preserves selector presence through local custody, sessions,
//! and local-to-foreign forwarding. Null with nonzero length refuses admission.
const std = @import("std");
const c = @import("c_abi");
const cd = @import("c_abi_host");
const h = @import("harness.zig");

const Probe = struct { calls: usize = 0, last: i64 = -1 };
fn reflect(ctx: ?*anyopaque, _: ?*cd.GlowcapHostTurn, verb: ?[*]const u8, len: usize, _: ?[*]const c.GlowcapArgument, count: usize, out: *c.GlowcapArgument) callconv(.c) i32 {
    const probe: *Probe = @ptrCast(@alignCast(ctx.?));
    const shape: i64 = if (verb == null) 0 else if (len == 0) 1 else if (std.mem.eql(u8, verb.?[0..len], "call")) 2 else return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    probe.calls += 1;
    probe.last = shape + 10 * @as(i64, @intCast(count));
    out.* = h.argInt(probe.last);
    return c.GLOWCAP_OK;
}

fn forward(ctx: ?*anyopaque, turn: ?*cd.GlowcapHostTurn, verb: ?[*]const u8, len: usize, args: ?[*]const c.GlowcapArgument, count: usize, out: *c.GlowcapArgument) callconv(.c) i32 {
    const target: *const c.GlowcapReference = @ptrCast(@alignCast(ctx.?));
    return cd.glowcap_host_turn_forward(turn, target, verb, len, args, count, out);
}

test "Host C invocation presence survives local, session, and forwarded delivery" {
    const client = try h.newHost(0x63);
    defer _ = cd.glowcap_host_release(client);
    const server = try h.newHost(0x64);
    defer _ = cd.glowcap_host_release(server);
    const hosts = [_]?*cd.GlowcapHost{ client, server };
    var dials = h.Dials{};
    var opening = h.Watches{};
    const pair = try h.openPair(&hosts, client, server, "127.0.0.1:7971", &dials, &opening);
    var probe = Probe{};
    var local: c.GlowcapReference = undefined;
    try h.expectOk(cd.glowcap_host_spawn(client, reflect, &probe, null, &local));
    var published: c.GlowcapReference = undefined;
    try h.expectOk(cd.glowcap_host_session_publish(pair.b, "shape", 5, reflect, &probe, null, &published));
    var fetched = h.CapturedSettle{};
    var fetched_vow: u64 = undefined;
    try h.expectOk(cd.glowcap_host_session_fetch(pair.a, "shape", 5, &fetched_vow));
    opening.add(client, fetched_vow, &fetched);
    try h.pump(&hosts, &.{pair}, &dials, &opening);
    var remote = try fetched.requireRef();
    var proxy: c.GlowcapReference = undefined;
    try h.expectOk(cd.glowcap_host_spawn(client, forward, &remote, null, &proxy));
    try h.expectOk(cd.glowcap_host_set_trace_queue(server, 16, 64));
    const selectors = [_]?[]const u8{ null, "", "call" };
    const args = [_]c.GlowcapArgument{h.argInt(37)};
    for (selectors, 0..) |selector, shape| {
        const ptr: ?[*]const u8 = if (selector) |method| method.ptr else null;
        const len = if (selector) |method| method.len else 0;
        for (0..2) |count| {
            const expected: i64 = @intCast(shape + 10 * count);
            for (0..3) |path| {
                var watches = h.Watches{};
                var captured = h.CapturedSettle{};
                var vow: u64 = undefined;
                try h.expectOk(switch (path) {
                    0 => cd.glowcap_host_send(client, &local, ptr, len, &args, count, &vow),
                    1 => cd.glowcap_host_session_send(pair.a, &remote, ptr, len, &args, count, &vow),
                    else => cd.glowcap_host_send(client, &proxy, ptr, len, &args, count, &vow),
                });
                watches.add(client, vow, &captured);
                try h.pump(&hosts, &.{pair}, &dials, &watches);
                std.testing.expect(captured.fired) catch |err| {
                    std.debug.print("invocation: shape={d}, args={d}, path={d}, calls={d}\n", .{ shape, count, path, probe.calls });
                    return err;
                };
                try std.testing.expectEqual(c.GLOWCAP_RESOLUTION_FULFILL, captured.kind);
                try std.testing.expectEqual(expected, captured.value.integer);
                const before = probe.calls;
                try h.expectOk(switch (path) {
                    0 => cd.glowcap_host_tell(client, &local, ptr, len, &args, count),
                    1 => cd.glowcap_host_session_tell(pair.a, &remote, ptr, len, &args, count),
                    else => cd.glowcap_host_tell(client, &proxy, ptr, len, &args, count),
                });
                try h.pump(&hosts, &.{pair}, &dials, &watches);
                try std.testing.expectEqual(before + 1, probe.calls);
                try std.testing.expectEqual(expected, probe.last);
                var trace: cd.GlowcapTraceEvent = undefined;
                var inbound: usize = 0;
                while (cd.glowcap_host_next_trace(server, &trace) == c.GLOWCAP_OK) {
                    if (trace.kind != cd.GLOWCAP_TRACE_MESSAGE or trace.outbound != 0) continue;
                    inbound += 1;
                    try std.testing.expectEqual(selector != null, trace.verb != null);
                    try std.testing.expectEqual(len, trace.verb_len);
                    if (selector) |method| try std.testing.expectEqualStrings(method, trace.verb.?[0..trace.verb_len]);
                }
                try std.testing.expectEqual(@as(usize, if (path == 0) 0 else 2), inbound);
            }
        }
    }
    const before = probe.calls;
    var refused: u64 = 0xdead;
    try std.testing.expectEqual(c.GLOWCAP_ERR_NULL_POINTER, cd.glowcap_host_send(client, &local, null, 1, null, 0, &refused));
    try std.testing.expectEqual(@as(u64, 0xdead), refused);
    try std.testing.expectEqual(before, probe.calls);
}

fn echoAndRelease(ctx: ?*anyopaque, _: ?*cd.GlowcapHostTurn, _: ?[*]const u8, _: usize, args: ?[*]const c.GlowcapArgument, count: usize, reply: *c.GlowcapArgument) callconv(.c) i32 {
    const host: *cd.GlowcapHost = @ptrCast(ctx.?);
    if (count != 1) return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    reply.* = args.?[0];
    return cd.glowcap_host_ref_release(host, &reply.reference, 1);
}

test "Host C callback can release sender-owned arguments before returning their borrowed reply" {
    const client = try h.newHost(0x67);
    defer _ = cd.glowcap_host_release(client);
    const server = try h.newHost(0x68);
    defer _ = cd.glowcap_host_release(server);
    const hosts = [_]?*cd.GlowcapHost{ client, server };
    var dials = h.Dials{};
    var watches = h.Watches{};
    const pair = try h.openPair(&hosts, client, server, "127.0.0.1:7972", &dials, &watches);
    var probe = Probe{};
    var callback: c.GlowcapReference = undefined;
    try h.expectOk(cd.glowcap_host_spawn(client, reflect, &probe, null, &callback));
    var published: c.GlowcapReference = undefined;
    try h.expectOk(cd.glowcap_host_session_publish(pair.b, "echo", 4, echoAndRelease, server, null, &published));
    var fetched = h.CapturedSettle{};
    var ticket: u64 = undefined;
    try h.expectOk(cd.glowcap_host_session_fetch(pair.a, "echo", 4, &ticket));
    watches.add(client, ticket, &fetched);
    try h.pump(&hosts, &.{pair}, &dials, &watches);
    const target = try fetched.requireRef();
    const server_live = try cd.testing.liveCapabilityCount(server);
    const arg = h.argRef(callback);
    var echoed = h.CapturedSettle{};
    var pending = h.Watches{};
    try h.expectOk(cd.glowcap_host_session_send(pair.a, &target, "echo", 4, @ptrCast(&arg), 1, &ticket));
    pending.add(client, ticket, &echoed);
    try h.pump(&hosts, &.{pair}, &dials, &pending);
    try std.testing.expect(echoed.fired);
    try std.testing.expectEqual(c.GLOWCAP_RESOLUTION_FULFILL, echoed.kind);
    try std.testing.expectEqual(callback.id, (try echoed.requireRef()).id);
    try std.testing.expectEqual(server_live, try cd.testing.liveCapabilityCount(server));
}
