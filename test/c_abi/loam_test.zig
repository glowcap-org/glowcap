//! Loam C boundary tests. Zig graph and transaction rules own the outcome.
const std = @import("std");
const c = @import("c_abi_loam");
const n = @import("c_abi_loam_lmdb");
const shared = @import("c_abi_shared");
const h = @import("c_abi_host");

test "Loam C policy terms enforce dependency masks and reject undeclared rows" {
    var policy = std.mem.zeroes(c.GlowcapLoamPolicy);
    policy.identity = @splat(5);
    policy.permissions[0] = 10;
    policy.permissions[1] = 20;
    policy.permission_count = 2;
    policy.prerequisite_masks[1] = 1;
    var demand = std.mem.zeroes(c.GlowcapLoamRequirement);
    demand.permission_count = 1;
    demand.permissions[0] = 20;
    var result: c.GlowcapLoamPolicyValue = undefined;
    try std.testing.expect(c.glowcap_loam_policy_value(&policy, &demand, &result) != shared.GLOWCAP_OK);
    demand.permissions[0] = 10;
    demand.permissions[1] = 20;
    demand.permission_count = 2;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_policy_value(&policy, &demand, &result));
    policy.prerequisite_masks[2] = 1;
    try std.testing.expect(c.glowcap_loam_policy_value(&policy, &demand, &result) != shared.GLOWCAP_OK);
}
test "Loam C LMDB atomic resource creation and reopen" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const limits: c.GlowcapLoamLimits = .{ .resident_bytes = 4 * 1024 * 1024, .staging_bytes = 4 * 1024 * 1024, .cache_slots = 64, .max_leases = 128, .max_changes = 64, .max_references = 128, .max_operations = 32 };
    const schema: c.GlowcapLoamSchema = .{ .id = 7, .version = 1, .max_payload = 256, .max_edges = 8 };
    var backend: ?*n.GlowcapLoamLmdb = null;
    var store: ?*c.GlowcapLoamStore = null;
    const id: [16]u8 = @splat(3);
    var invalid_schema = schema;
    invalid_schema.version = 0;
    try std.testing.expect(n.glowcap_loam_lmdb_open(path.ptr, path.len, &id, 1, 8 * 1024 * 1024, @as([*]const c.GlowcapLoamSchema, @ptrCast(&invalid_schema)), 1, &limits, &backend, &store) != shared.GLOWCAP_OK);
    try std.testing.expect(backend == null and store == null);
    try std.testing.expectEqual(shared.GLOWCAP_OK, n.glowcap_loam_lmdb_open(path.ptr, path.len, &id, 1, 8 * 1024 * 1024, @as([*]const c.GlowcapLoamSchema, @ptrCast(&schema)), 1, &limits, &backend, &store));
    var policy = std.mem.zeroes(c.GlowcapLoamPolicy);
    policy.identity = @splat(5);
    policy.permissions[0] = 10;
    policy.permissions[1] = 20;
    policy.permission_count = 2;
    policy.prerequisite_masks[1] = 1;
    var resource: c.GlowcapLoamResource = undefined;
    try std.testing.expect(c.glowcap_loam_resource_stage(store, &policy, &id, 1, 999, 1, "invalid", 7, 2, &resource) != shared.GLOWCAP_OK);
    try std.testing.expectEqual(.idle, (try c.embedding.store(store)).value.phase);
    try std.testing.expectEqual(@as(usize, 0), (try c.embedding.store(store)).value.count);
    const rc = c.glowcap_loam_resource_stage(store, &policy, &id, 1, 7, 1, "initial", 7, 2, &resource);
    if (rc != shared.GLOWCAP_OK) {
        var buf: [512]u8 = undefined;
        const len = c.glowcap_loam_last_error(&buf, buf.len);
        std.debug.print("creation refusal: {s}\n", .{buf[0..len]});
    }
    try std.testing.expectEqual(shared.GLOWCAP_OK, rc);
    const staged_store = &(try c.embedding.store(store)).value;
    const access = @import("loam_access");
    const endpoint = try access.records.EndpointRecord.decode((try staged_store.proposed(try c.embedding.object(resource.use))).?.view);
    const content_view = (try staged_store.proposed(endpoint.content.?.object)).?.view;
    var edges = content_view.edges();
    const binding = edges.next().?;
    try std.testing.expectEqual(.strong, binding.strength);
    try std.testing.expectEqual(.object, binding.restoration);
    try std.testing.expect(edges.next() == null);
    const managed = try access.records.ResourceRecord.decode((try staged_store.proposed(binding.target)).?.view);
    try std.testing.expect(managed.resource.id.eql(endpoint.content.?.resource));
    try std.testing.expectEqual(shared.GLOWCAP_OK, n.glowcap_loam_lmdb_commit(backend));
    try std.testing.expectEqual(shared.GLOWCAP_OK, n.glowcap_loam_lmdb_release(backend));
    try std.testing.expectEqual(shared.GLOWCAP_OK, n.glowcap_loam_lmdb_open(path.ptr, path.len, &id, 0, 8 * 1024 * 1024, @as([*]const c.GlowcapLoamSchema, @ptrCast(&schema)), 1, &limits, &backend, &store));
    try checkOwnershipAndWorkers(backend.?, store.?, resource);
    try std.testing.expectEqual(shared.GLOWCAP_OK, n.glowcap_loam_lmdb_release(backend));
}

fn complete(work: ?*c.GlowcapLoamWork) i32 {
    var completed: u32 = 0;
    return c.glowcap_loam_work_complete(work, &completed);
}

fn requirements(_: ?*anyopaque, _: *const c.GlowcapLoamInvocation, out: *c.GlowcapLoamRequirement) callconv(.c) i32 {
    out.* = std.mem.zeroes(c.GlowcapLoamRequirement);
    return shared.GLOWCAP_OK;
}
fn invoke(_: ?*anyopaque, call: *c.GlowcapLoamCall, _: *const c.GlowcapLoamInvocation) callconv(.c) i32 {
    var value = std.mem.zeroes(shared.GlowcapArgument);
    value.kind = shared.GLOWCAP_ARG_VOID;
    return c.glowcap_loam_call_reply(call, &value);
}
fn entropy(_: ?*anyopaque, bytes: [*]u8, len: usize) callconv(.c) i32 {
    @memset(bytes[0..len], 9);
    return shared.GLOWCAP_OK;
}
fn checkOwnershipAndWorkers(backend: *n.GlowcapLoamLmdb, store: *c.GlowcapLoamStore, resource: c.GlowcapLoamResource) !void {
    const seed: [64]u8 = @splat(8);
    var host: ?*h.GlowcapHost = null;
    try std.testing.expectEqual(shared.GLOWCAP_OK, h.glowcap_host_new(&seed, seed.len, 4096, 1, shared.GLOWCAP_CODEC_SYRUP, shared.GLOWCAP_CAPTP_V1_0, shared.GLOWCAP_FEATURE_FULL, 0, &host));
    const methods = [_]c.GlowcapLoamMethod{.{ .verb = "get", .verb_len = 3, .retry = 0 }};
    const contents = [_]c.GlowcapLoamContent{.{ .schema = 7, .version = 1, .context = null, .methods = &methods, .method_count = methods.len, .requirement = requirements, .invoke = invoke }};
    var attachment: ?*c.GlowcapLoamAttachment = null;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_attach(store, host, &contents, contents.len, entropy, null, &attachment));
    try std.testing.expectEqual(shared.GLOWCAP_ERR_INVALID_ARGUMENT, h.glowcap_host_release(host));
    try std.testing.expectEqual(shared.GLOWCAP_ERR_WOULD_BLOCK, n.glowcap_loam_lmdb_release(backend));
    var ref: shared.GlowcapReference = undefined;
    try std.testing.expectEqual(shared.GLOWCAP_OK, n.glowcap_loam_lmdb_restore(backend, attachment, &resource.use, &ref));
    const owner = try c.embedding.attachment(attachment);
    try @import("loam_vocabulary.zig").check(&owner.service);
    const core_store = &(try c.embedding.store(store)).value;
    const capability = owner.host_borrow.core().capabilityFromRaw(ref.id);
    core_store.evict();
    try owner.value.prefetch(capability);
    var work: ?*c.GlowcapLoamWork = null;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_next_work(attachment, 0, &work));
    try std.testing.expect(work != null);
    try std.testing.expectEqual(shared.GLOWCAP_ERR_WOULD_BLOCK, c.glowcap_loam_attachment_release(attachment));
    try std.testing.expectEqual(shared.GLOWCAP_ERR_WOULD_BLOCK, c.glowcap_loam_work_release(work));
    try std.testing.expectEqual(c.GLOWCAP_LOAM_ERR_STALE_COMPLETION, complete(work));
    try std.testing.expectEqual(shared.GLOWCAP_OK, n.glowcap_loam_lmdb_work_run(backend, work));
    try std.testing.expectEqual(c.GLOWCAP_LOAM_ERR_STALE_COMPLETION, n.glowcap_loam_lmdb_work_run(backend, work));
    var completed: u32 = 1;
    owner.host_borrow.core().in_callback = true;
    const reentered = c.glowcap_loam_work_complete(work, &completed);
    owner.host_borrow.core().in_callback = false;
    try std.testing.expectEqual(shared.GLOWCAP_ERR_INVALID_ARGUMENT, reentered);
    try std.testing.expectEqual(@as(u32, 0), completed);
    try std.testing.expectEqual(shared.GLOWCAP_ERR_WOULD_BLOCK, c.glowcap_loam_work_release(work));
    try std.testing.expectEqual(shared.GLOWCAP_OK, complete(work));
    try std.testing.expectEqual(c.GLOWCAP_LOAM_ERR_STALE_COMPLETION, complete(work));
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_work_release(work));

    // A joined write can lose its acknowledgement. Recovery selects the same
    // batch automatically and preserves the uncertain barrier until proof.
    try core_store.begin();
    const object = try core_store.allocateId();
    try core_store.putCopying(.{ .id = object, .revision = 0, .schema = 7, .payload = "recovered", .edges = &.{} }, null);
    _ = try owner.value.submit();
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_next_work(attachment, 0, &work));
    try std.testing.expectEqual(shared.GLOWCAP_OK, n.glowcap_loam_lmdb_work_run(backend, work));
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_work_report_unknown(work));
    try std.testing.expectEqual(c.GLOWCAP_LOAM_ERR_RECOVERY_REQUIRED, complete(work));
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_work_release(work));
    try std.testing.expectEqual(.uncertain, core_store.phase);
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_next_work(attachment, 0, &work));
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_work_report_unstarted(work));
    try std.testing.expectEqual(c.GLOWCAP_LOAM_ERR_RECOVERY_REQUIRED, complete(work));
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_work_release(work));
    try std.testing.expectEqual(.uncertain, core_store.phase);
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_next_work(attachment, 0, &work));
    try std.testing.expectEqual(shared.GLOWCAP_OK, n.glowcap_loam_lmdb_work_run(backend, work));
    try std.testing.expectEqual(shared.GLOWCAP_OK, complete(work));
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_work_release(work));
    try std.testing.expectEqual(.idle, core_store.phase);
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_attachment_release(attachment));
    try std.testing.expectEqual(shared.GLOWCAP_OK, h.glowcap_host_ref_release(host, &ref, 1));
    try std.testing.expectEqual(shared.GLOWCAP_OK, h.glowcap_host_release(host));
}

test "Loam context allocator owns construction, refused attach and teardown" {
    const root = @import("c_abi");
    const core = @import("loam_core");
    const CountingHost = @import("support_c_abi_counting_alloc").CountingHost;
    var counter: CountingHost = .{};
    const spec = counter.spec();
    var context: ?*root.GlowcapContext = null;
    try std.testing.expectEqual(shared.GLOWCAP_OK, root.glowcap_context_new_with_allocator(&spec, &context));
    const metadata = (core.Metadata{ .store = @fromBackingInt(3), .incarnation = 1 }).encode();
    const limits: c.GlowcapLoamLimits = .{ .resident_bytes = 4 * 1024 * 1024, .staging_bytes = 4 * 1024 * 1024, .cache_slots = 64, .max_leases = 128, .max_changes = 64, .max_references = 128, .max_operations = 32 };
    const schemas = [_]c.GlowcapLoamSchema{.{ .id = 7, .version = 1, .max_payload = 256, .max_edges = 8 }};
    var store: ?*c.GlowcapLoamStore = null;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_store_new_in(context, &metadata, metadata.len, &schemas, schemas.len, &limits, &store));
    const store_bytes = counter.live_bytes;
    const seed: [64]u8 = @splat(8);
    var host: ?*h.GlowcapHost = null;
    try std.testing.expectEqual(shared.GLOWCAP_OK, h.glowcap_host_new(&seed, seed.len, 4096, 1, shared.GLOWCAP_CODEC_SYRUP, shared.GLOWCAP_CAPTP_V1_0, shared.GLOWCAP_FEATURE_FULL, 0, &host));
    const methods = [_]c.GlowcapLoamMethod{.{ .verb = "get", .verb_len = 3, .retry = 0 }};
    const contents = [_]c.GlowcapLoamContent{.{ .schema = 7, .version = 1, .context = null, .methods = &methods, .method_count = 1, .requirement = requirements, .invoke = invoke }};
    var attachment: ?*c.GlowcapLoamAttachment = null;
    counter.allocations_before_failure = 2;
    try std.testing.expectEqual(shared.GLOWCAP_ERR_INTERNAL, c.glowcap_loam_attach(store, host, &contents, contents.len, entropy, null, &attachment));
    try std.testing.expect(attachment == null);
    try std.testing.expectEqual(store_bytes, counter.live_bytes);
    counter.allocations_before_failure = null;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_attach(store, host, &contents, contents.len, entropy, null, &attachment));
    try std.testing.expect(counter.live_bytes > store_bytes);
    try std.testing.expectEqual(shared.GLOWCAP_ERR_WOULD_BLOCK, c.glowcap_loam_store_release(store));
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_attachment_release(attachment));
    try std.testing.expectEqual(store_bytes, counter.live_bytes);
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_store_release(store));
    root.glowcap_context_release(context);
    try std.testing.expect(counter.balanced());
    try std.testing.expectEqual(shared.GLOWCAP_OK, h.glowcap_host_release(host));
}
