//! Releasing an attachment whose live startup failed. A failed confirmation
//! keeps its proposal until the Store is idle, so a release while a
//! transaction is staged on that Store refuses with the attachment intact,
//! and the same release succeeds once the Store is idle again.
const std = @import("std");
const c = @import("c_abi_loam");
const n = @import("c_abi_loam_volatile");
const h = @import("c_abi_host");
const shared = @import("c_abi_shared");
const callbacks = @import("loam_callbacks.zig");

const limits: c.GlowcapLoamLimits = .{ .resident_bytes = 4 * 1024 * 1024, .staging_bytes = 4 * 1024 * 1024, .cache_slots = 64, .max_leases = 128, .max_changes = 64, .max_references = 128, .max_operations = 32, .record_capacity = 32, .max_reference_saves = 96, .max_retentions = 256, .max_continuations = 2, .continuation_bytes = 4096, .max_continuation_targets = 3, .forward_reply_bytes = 3072 };
const schema: c.GlowcapLoamSchema = .{ .id = 7, .version = 1, .max_payload = 256, .max_edges = 8 };
const methods = [_]c.GlowcapLoamMethod{.{ .verb = "get", .verb_len = 3, .retry = 0 }};
const contents = [_]c.GlowcapLoamContent{.{ .schema = 7, .version = 1, .context = null, .methods = &methods, .method_count = methods.len, .requirement = callbacks.requirements, .invoke = callbacks.invoke }};

const Work = enum(u32) { read = 0, write = 1 };

/// Advance `attachment` once and take the one piece of work it submits.
fn nextWork(attachment: ?*c.GlowcapLoamAttachment, expected: Work) !*c.GlowcapLoamWork {
    var progress: u32 = 0;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_advance(attachment, &progress));
    var work: ?*c.GlowcapLoamWork = null;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_next_work(attachment, 0, &work));
    var kind: u32 = 0;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_work_kind(work, &kind));
    try std.testing.expectEqual(@backingInt(expected), kind);
    return work.?;
}

fn finish(work: *c.GlowcapLoamWork) !void {
    var completed: u32 = 0;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_work_complete(work, &completed));
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_work_release(work));
}

fn run(backend: ?*n.GlowcapLoamVolatile, work: *c.GlowcapLoamWork) !void {
    try std.testing.expectEqual(shared.GLOWCAP_OK, n.glowcap_loam_volatile_work_run(backend, work));
    try finish(work);
}

test "Loam live release refuses whole while a failed startup's proposal waits on a staged Store" {
    const id: [16]u8 = @splat(4);
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
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_live_start(attachment, null, 1));

    // The marker write commits, and the confirming read never starts, so
    // startup fails holding its committed proposal.
    try run(backend, try nextWork(attachment, .write));
    const confirm = try nextWork(attachment, .read);
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_work_report_unstarted(confirm));
    var completed: u32 = 0;
    try std.testing.expectEqual(shared.GLOWCAP_ERR_IO, c.glowcap_loam_work_complete(confirm, &completed));
    try std.testing.expectEqual(@as(u32, 1), completed);
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_work_release(confirm));
    var marker: c.GlowcapLoamObject = undefined;
    try std.testing.expectEqual(shared.GLOWCAP_ERR_IO, c.glowcap_loam_live_marker(attachment, &marker));

    // An embedding transaction holds the Store out of idle.
    const owner = try c.embedding.attachment(attachment);
    try owner.store.value.begin();
    try std.testing.expectEqual(shared.GLOWCAP_ERR_WOULD_BLOCK, c.glowcap_loam_attachment_release(attachment));
    // The refusal changed nothing: the attachment still answers as before.
    try std.testing.expect(owner.live_scope != null);
    try std.testing.expectEqual(shared.GLOWCAP_ERR_IO, c.glowcap_loam_live_marker(attachment, &marker));

    try owner.store.value.abort();
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_attachment_release(attachment));
}
