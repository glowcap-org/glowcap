//! A runtime's memory retry deadline on a Host the C Loam attachment drives.
//! `glowcap_loam_advance` reports progress while the Host holds runnable
//! work, and none while the runtime has armed its retry deadline over that
//! work, so a C progress loop parks until the deadline instead of spinning.
//! The runtime arms the deadline through its own close-tail policy and clears
//! it through its own due attempt, on a clock the test moves.
const std = @import("std");
const glowcap = @import("glowcap");
const c = @import("c_abi_loam");
const n = @import("c_abi_loam_volatile");
const h = @import("c_abi_host");
const shared = @import("c_abi_shared");
const callbacks = @import("loam_callbacks.zig");
const SteppedClock = @import("support_stepped_clock").SteppedClock;

const limits: c.GlowcapLoamLimits = .{ .resident_bytes = 4 * 1024 * 1024, .staging_bytes = 4 * 1024 * 1024, .cache_slots = 64, .max_leases = 128, .max_changes = 64, .max_references = 128, .max_operations = 32, .record_capacity = 32, .max_reference_saves = 96, .max_retentions = 256, .max_continuations = 2, .continuation_bytes = 4096, .max_continuation_targets = 3, .forward_reply_bytes = 3072 };
const schema: c.GlowcapLoamSchema = .{ .id = 7, .version = 1, .max_payload = 256, .max_edges = 8 };
const methods = [_]c.GlowcapLoamMethod{.{ .verb = "get", .verb_len = 3, .retry = 0 }};
const contents = [_]c.GlowcapLoamContent{.{ .schema = 7, .version = 1, .context = null, .methods = &methods, .method_count = methods.len, .requirement = callbacks.requirements, .invoke = callbacks.invoke }};

fn advance(attachment: ?*c.GlowcapLoamAttachment) !u32 {
    var progress: u32 = 99;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_advance(attachment, &progress));
    return progress;
}

test "glowcap_loam_advance reports no progress while the runtime's retry deadline gates queued work" {
    const id: [16]u8 = @splat(5);
    var backend: ?*n.GlowcapLoamVolatile = null;
    var store: ?*c.GlowcapLoamStore = null;
    try std.testing.expectEqual(shared.GLOWCAP_OK, n.glowcap_loam_volatile_open(&id, 1, 8 * 1024 * 1024, @as([*]const c.GlowcapLoamSchema, @ptrCast(&schema)), 1, &limits, &backend, &store));
    // tolerant: a failed step above leaves the attachment live, and the test already reports that failure.
    defer _ = n.glowcap_loam_volatile_release(backend);
    const seed: [64]u8 = @splat(8);
    var host: ?*h.GlowcapHost = null;
    try std.testing.expectEqual(shared.GLOWCAP_OK, h.glowcap_host_new(&seed, seed.len, 4096, 1, shared.GLOWCAP_CODEC_SYRUP, shared.GLOWCAP_CAPTP_V1_0, shared.GLOWCAP_FEATURE_FULL, 0, 1, &host));
    // tolerant: as above, an earlier failure is the one the test reports.
    defer _ = h.glowcap_host_release(host);
    var attachment: ?*c.GlowcapLoamAttachment = null;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_attach(store, host, &contents, contents.len, callbacks.entropy, null, &attachment));
    defer std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_attachment_release(attachment)) catch @panic("attachment release failed");
    const owner = try c.embedding.attachment(attachment);
    const core = owner.host_borrow.core();

    // Queued Host work: a dial the core owes its transport.
    _ = try core.enlivenSelectOrDial(.{
        .peer = .{ .transport = glowcap.ocapn.model.transport.tcp, .designator = "127.0.0.1:7095", .hints = glowcap.ocapn.model.Hints.emptyFalse() },
        .swissnum = "retry-gate",
    });
    try std.testing.expect(core.hasRunnableWork());
    try std.testing.expectEqual(@as(u32, 1), try advance(attachment));

    const HostRuntime = glowcap.driver.HostRuntime;
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var clock = SteppedClock.init(threaded.io(), 0, 0);
    var runtime = try HostRuntime.initWithCore(std.testing.allocator, clock.io(), core, .{}, .{
        .handshake = .{ .ms = 10_000 },
        .settle = .{ .ms = 10_000 },
    });
    defer runtime.deinit();
    // The runtime's own policy arms the deadline over that work, and the C
    // progress call parks the loop instead of reporting it.
    HostRuntime.testing.closeTailFailed(&runtime, error.OutOfMemory);
    try runtime.detachThread();
    try std.testing.expect(core.memory_retry_due_ms != null);
    try std.testing.expectEqual(@as(u32, 0), try advance(attachment));
    // Past due the work still waits for the runtime's attempt to run.
    clock.advanceMs(HostRuntime.testing.memory_retry_ms);
    try std.testing.expectEqual(@as(u32, 0), try advance(attachment));
    try std.testing.expect(core.memory_retry_due_ms != null);

    // The runtime's due attempt runs the work and clears the deadline.
    try std.testing.expectEqual(HostRuntime.testing.Drain.complete, try HostRuntime.testing.attempt(&runtime, .operational, .turn));
    try std.testing.expectEqual(@as(?i64, null), core.memory_retry_due_ms);
    try std.testing.expect(!core.hasRunnableWork());
}
