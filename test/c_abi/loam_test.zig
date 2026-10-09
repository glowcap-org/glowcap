//! Loam C boundary tests. Zig graph and transaction rules own the outcome.
const std = @import("std");
const c = @import("c_abi_loam");
const n = @import("c_abi_loam_lmdb");
const shared = @import("c_abi_shared");
const h = @import("c_abi_host");

test "Loam C forwarding sizing admits complete replies and zeroes refused outputs" {
    const shape: c.GlowcapLoamValueBounds = .{ .values = 2048, .struct_entries = 0, .bytes = 8 * 1024 * 1024, .capabilities = 0 };
    var reply_bytes: usize = 0;
    var call_bytes: usize = 0;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_forwarding_size_bound(&shape, &reply_bytes, &call_bytes));
    // The full reply fits a 32-bit eight-operation profile. An unrelated C
    // projection of every possible value in this byte buffer must not inflate it.
    try std.testing.expect(reply_bytes >= shape.bytes);
    try std.testing.expect(call_bytes > reply_bytes);
    try std.testing.expect(call_bytes <= std.math.maxInt(u32) / 8);
    const hosting = @import("loam_hosting");
    var memory: hosting.Call.Memory = undefined;
    memory.init(std.testing.allocator, call_bytes);
    defer memory.deinit();
    const payload = try memory.input.allocator().alloc(u8, reply_bytes);
    @memset(payload, 'r');
    try std.testing.expectEqual(@as(u8, 'r'), payload[payload.len - 1]);
    const invalid: c.GlowcapLoamValueBounds = .{ .values = 1, .struct_entries = 0, .bytes = std.math.maxInt(usize), .capabilities = 0 };
    try std.testing.expect(c.glowcap_loam_forwarding_size_bound(&invalid, &reply_bytes, &call_bytes) != shared.GLOWCAP_OK);
    try std.testing.expectEqual(@as(usize, 0), reply_bytes);
    try std.testing.expectEqual(@as(usize, 0), call_bytes);
    reply_bytes = 999;
    try std.testing.expectEqual(shared.GLOWCAP_ERR_NULL_POINTER, c.glowcap_loam_forwarding_size_bound(&shape, &reply_bytes, null));
    try std.testing.expectEqual(@as(usize, 0), reply_bytes);
}

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
    policy.prerequisite_masks[2] = 0;
    policy.permissions[2] = 30;
    policy.permission_count = 3;
    policy.kind_rules[0] = .{ .kind = 1, .permissions = 3, .subtree_permissions = 3 };
    policy.kind_count = 1;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_policy_value_for_kind(&policy, 1, &demand, &result));
    demand.permission_count = 1;
    demand.permissions[0] = 30;
    try std.testing.expect(c.glowcap_loam_policy_value_for_kind(&policy, 1, &demand, &result) != shared.GLOWCAP_OK);
    try std.testing.expect(c.glowcap_loam_policy_value_for_kind(&policy, 2, &demand, &result) != shared.GLOWCAP_OK);
}
test "Loam C schema sizing reports complete bytes and refuses overflow without storage" {
    var schema: c.GlowcapLoamSchema = .{ .id = 7, .version = 1, .max_payload = 256, .max_edges = 8 };
    var bytes: usize = 999;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_schema_size_bound(&schema, &bytes));
    const core_schema: @import("loam_core").Schema = .{ .id = schema.id, .version = schema.version, .max_payload = schema.max_payload, .max_edges = schema.max_edges };
    try std.testing.expectEqual(try core_schema.encodedSizeBound(), bytes);
    schema.max_payload = std.math.maxInt(usize);
    try std.testing.expect(c.glowcap_loam_schema_size_bound(&schema, &bytes) != shared.GLOWCAP_OK);
    try std.testing.expectEqual(@as(usize, 0), bytes);
    bytes = 999;
    try std.testing.expectEqual(shared.GLOWCAP_ERR_NULL_POINTER, c.glowcap_loam_schema_size_bound(null, &bytes));
    try std.testing.expectEqual(@as(usize, 0), bytes);
    try std.testing.expectEqual(shared.GLOWCAP_ERR_NULL_POINTER, c.glowcap_loam_schema_size_bound(&schema, null));
}

test "Loam C staging sizing separates row families and resets refused output" {
    var bound: c.GlowcapLoamStagingBounds = undefined;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_content_staging_size_bound(1, 0, &bound));
    try std.testing.expectEqual(@as(usize, 4), bound.changes);
    const plain = bound;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_content_staging_size_bound(1, 1, &bound));
    try std.testing.expectEqual(plain.changes + 2, bound.changes);
    try std.testing.expect(bound.staging_bytes > plain.staging_bytes);
    try std.testing.expect(bound.record_bytes <= bound.staging_bytes);
    const access = @import("loam_access");
    const path = access.records.ChangeBatchRecord.max_path;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_content_staging_size_bound(path, 1, &bound));
    try std.testing.expectEqual(path + 5, bound.changes);
    for ([_][2]usize{ .{ 0, 1 }, .{ path + 1, 1 }, .{ 1, 2 } }) |input| {
        bound = .{ .changes = 999, .staging_bytes = 999, .record_bytes = 999 };
        try std.testing.expect(c.glowcap_loam_content_staging_size_bound(input[0], @intCast(input[1]), &bound) != shared.GLOWCAP_OK);
        try std.testing.expectEqual(std.mem.zeroes(c.GlowcapLoamStagingBounds), bound);
    }
    try std.testing.expectEqual(shared.GLOWCAP_ERR_NULL_POINTER, c.glowcap_loam_content_staging_size_bound(1, 1, null));
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_reference_staging_size_bound(3592, &bound));
    const recipe_bytes = try @import("loam_hosting").references.schema.encodedSizeBound();
    try std.testing.expectEqual(@as(usize, 3592), bound.changes);
    try std.testing.expectEqual(recipe_bytes, bound.record_bytes);
    try std.testing.expectEqual(3592 * recipe_bytes, bound.staging_bytes);
    try std.testing.expect(c.glowcap_loam_reference_staging_size_bound(std.math.maxInt(usize), &bound) != shared.GLOWCAP_OK);
    try std.testing.expectEqual(std.mem.zeroes(c.GlowcapLoamStagingBounds), bound);
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_reference_staging_size_bound(0, &bound));
    try std.testing.expectEqual(std.mem.zeroes(c.GlowcapLoamStagingBounds), bound);
    try std.testing.expectEqual(shared.GLOWCAP_ERR_NULL_POINTER, c.glowcap_loam_reference_staging_size_bound(0, null));
}

test "Loam C reference sizing retains empty preparation and resets refused output" {
    var bytes: usize = 999;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_reference_call_size_bound(0, 0, 0, &bytes));
    try std.testing.expect(bytes != 0);
    const empty = bytes;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_reference_call_size_bound(3592, 3592, 4096, &bytes));
    try std.testing.expect(bytes > empty);
    const shared_bound = try @import("loam_hosting").references.allocationBound(3592, 3592, 4096);
    // C consumes borrowed declaration buffers by copying before return.
    try std.testing.expect(bytes > try shared_bound.physicalBytes());
    for ([_][3]usize{ .{ 1, 1, 4097 }, .{ std.math.maxInt(usize), 1, 4096 }, .{ 0, std.math.maxInt(usize), 0 } }) |input| {
        bytes = 999;
        try std.testing.expect(c.glowcap_loam_reference_call_size_bound(input[0], input[1], input[2], &bytes) != shared.GLOWCAP_OK);
        try std.testing.expectEqual(@as(usize, 0), bytes);
    }
    try std.testing.expectEqual(shared.GLOWCAP_ERR_NULL_POINTER, c.glowcap_loam_reference_call_size_bound(0, 0, 0, null));
}

test "Loam C graph sizing includes empty root work and resets overflow output" {
    var bytes: usize = 999;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_graph_call_size_bound(0, 0, 0, &bytes));
    try std.testing.expect(bytes != 0);
    const empty = bytes;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_graph_call_size_bound(63, 1024 * 1024, 3592, &bytes));
    try std.testing.expect(bytes > empty);
    const core_bound = try @import("loam_access").hosting.graphAllocationBound(63, 1024 * 1024, 3592);
    try std.testing.expect(bytes > try core_bound.physicalBytes());
    for ([_][3]usize{ .{ std.math.maxInt(usize), 0, 0 }, .{ 1, std.math.maxInt(usize), 0 }, .{ 1, 0, std.math.maxInt(usize) } }) |input| {
        bytes = 999;
        try std.testing.expect(c.glowcap_loam_graph_call_size_bound(input[0], input[1], input[2], &bytes) != shared.GLOWCAP_OK);
        try std.testing.expectEqual(@as(usize, 0), bytes);
    }
    try std.testing.expectEqual(shared.GLOWCAP_ERR_NULL_POINTER, c.glowcap_loam_graph_call_size_bound(0, 0, 0, null));
}

test "Loam C invocation sizing describes complete input and persisted reply topology" {
    var shape = std.mem.zeroes(c.GlowcapLoamInvocationBounds);
    shape.reply.values = 1;
    var bytes: usize = 999;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_invocation_call_size_bound(&shape, &bytes));
    const empty = bytes;
    try std.testing.expect(empty != 0);
    shape.arguments = .{ .values = 4, .struct_entries = 0, .bytes = 3, .capabilities = 1 };
    shape.verb_bytes = 6;
    shape.held_occurrences = 3592;
    shape.receipt = 1;
    shape.dependent = 1;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_invocation_call_size_bound(&shape, &bytes));
    try std.testing.expect(bytes > empty);
    const valid = shape;
    for (0..5) |index| {
        shape = valid;
        switch (index) {
            0 => shape.arguments.values = std.math.maxInt(usize),
            1 => shape.reply.values = 0,
            2 => shape.receipt = 2,
            3 => shape.held_occurrences = std.math.maxInt(usize),
            4 => shape.arguments.capabilities = shape.arguments.values + 1,
            else => unreachable,
        }
        bytes = 999;
        try std.testing.expect(c.glowcap_loam_invocation_call_size_bound(&shape, &bytes) != shared.GLOWCAP_OK);
        try std.testing.expectEqual(@as(usize, 0), bytes);
    }
    bytes = 999;
    try std.testing.expectEqual(shared.GLOWCAP_ERR_NULL_POINTER, c.glowcap_loam_invocation_call_size_bound(null, &bytes));
    try std.testing.expectEqual(@as(usize, 0), bytes);
    try std.testing.expectEqual(shared.GLOWCAP_ERR_NULL_POINTER, c.glowcap_loam_invocation_call_size_bound(&valid, null));
}

test "Loam C value topology covers actual nested projections and owned reply conversion" {
    const hosting = @import("loam_hosting");
    const driver = @import("driver_core");
    const shape: hosting.ValueBounds = .{ .values = 6, .struct_entries = 2, .bytes = 523 };
    const value: driver.Value = .{ .tagged = .{ .tag = "outer", .value = &.{.{ .@"struct" = &.{
        .{ .key = "first", .value = .{ .string = &@as([513]u8, @splat('x')) } },
        .{ .key = "", .value = .{ .list = &.{ .{ .float64 = -0.0 }, .{ .void = {} } } } },
    } }} } };
    const Bound = hosting.references.AllocationBound;
    const projection = try h.embedding.valueProjectionBound(Bound, shape.values, shape.struct_entries);
    const copy = try hosting.valueAllocationBound(driver.Value, shape);
    var total = projection;
    try total.merge(copy);
    var memory: hosting.Call.Memory = undefined;
    memory.init(std.testing.allocator, try total.physicalBytes());
    defer memory.deinit();
    var traffic: @import("support_alloc_metrics").AllocationTraffic(Bound) = .{ .backing = memory.working.allocator() };
    const allocator = traffic.allocator();
    const args = try allocator.alloc(shared.GlowcapArgument, 1);
    args[0] = try h.embedding.valueToC(allocator, value);
    try std.testing.expect(traffic.demand.bytes <= projection.bytes);
    try std.testing.expect(traffic.demand.allocations <= projection.allocations);
    traffic.demand = .{};
    const Refused = struct {
        fn capability(_: void, _: shared.GlowcapReference) !driver.Capability {
            return error.UnexpectedCapability;
        }
    };
    const result = try shared.valuesFromCWith(driver.Value, anyerror, {}, Refused.capability, allocator, args.ptr, args.len, 0, true);
    try std.testing.expect(traffic.demand.bytes <= copy.bytes);
    try std.testing.expect(traffic.demand.allocations <= copy.allocations);
    try std.testing.expectEqualDeep(value, result[0]);
    try std.testing.expect(result[0].tagged.value[0].@"struct"[0].value.string.ptr != value.tagged.value[0].@"struct"[0].value.string.ptr);
}

test "Loam C LMDB atomic resource creation and reopen" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const limits: c.GlowcapLoamLimits = .{ .resident_bytes = 4 * 1024 * 1024, .staging_bytes = 4 * 1024 * 1024, .cache_slots = 64, .max_leases = 128, .max_changes = 64, .max_references = 128, .max_operations = 32, .record_capacity = 32, .max_reference_saves = 96, .max_retentions = 256, .max_continuations = 2, .continuation_bytes = 4096, .max_continuation_targets = 3, .forward_reply_bytes = 3072 };
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
    const content_id = content_view.id;
    // Keep validated committed records resident for the callback projection
    // witness. Its attachment starts only after creation has committed.
    staged_store.retain_committed = true;
    try std.testing.expectEqual(shared.GLOWCAP_OK, n.glowcap_loam_lmdb_commit(backend));
    try checkCallbackBinding(store.?, content_id, managed, binding.target);
    try checkRetentionQuota(store.?, resource.use, limits.max_retentions);
    try std.testing.expectEqual(shared.GLOWCAP_OK, n.glowcap_loam_lmdb_release(backend));
    try std.testing.expectEqual(shared.GLOWCAP_OK, n.glowcap_loam_lmdb_open(path.ptr, path.len, &id, 0, 8 * 1024 * 1024, @as([*]const c.GlowcapLoamSchema, @ptrCast(&schema)), 1, &limits, &backend, &store));
    try checkOwnershipAndWorkers(backend.?, store.?, resource);
    try std.testing.expectEqual(shared.GLOWCAP_OK, n.glowcap_loam_lmdb_release(backend));
}

fn checkRetentionQuota(raw: *c.GlowcapLoamStore, object: c.GlowcapLoamObject, capacity: usize) !void {
    const owner = try c.embedding.store(raw);
    const core = @import("loam_core");
    const tokens = try std.testing.allocator.alloc(core.Retention, capacity);
    defer std.testing.allocator.free(tokens);
    var count: usize = 0;
    defer for (tokens[0..count]) |token| owner.value.releaseRetention(token) catch unreachable;
    const id = try c.embedding.object(object);
    for (tokens) |*token| {
        token.* = try owner.value.retain(id);
        count += 1;
    }
    // Endpoint inventory remains 128 while 256 independent roots are held.
    try std.testing.expect(capacity > owner.limits.max_references);
    try std.testing.expectError(error.RetentionCapacity, owner.value.retain(id));
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
const ReferenceSizingProbe = struct {
    reference: shared.GlowcapReference = .{ .id = 0 },
    uri: [4096]u8 = @splat('x'),
    const saves = 33;
    fn declare(context: ?*anyopaque, raw: *c.GlowcapLoamReferences, _: *const c.GlowcapLoamInvocation) callconv(.c) i32 {
        const self: *ReferenceSizingProbe = @ptrCast(@alignCast(context.?));
        for (0..saves) |_| {
            const rc = c.glowcap_loam_references_save_copying(raw, &self.reference, &self.uri, self.uri.len);
            if (rc != shared.GLOWCAP_OK) return rc;
        }
        return shared.GLOWCAP_OK;
    }
};

const DeclarationTraffic = @import("support_alloc_metrics").AllocationTraffic(@import("loam_hosting").references.AllocationBound);

fn checkReferenceSizing(behavior: @import("loam_access").hosting.ContentBehavior, probe: *ReferenceSizingProbe, input: @import("loam_access").hosting.ContentInvocation) !void {
    const hosting = @import("loam_hosting");
    var bytes: usize = 0;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_reference_call_size_bound(0, ReferenceSizingProbe.saves, probe.uri.len, &bytes));
    var memory: hosting.Call.Memory = undefined;
    memory.init(std.testing.allocator, bytes);
    defer memory.deinit();
    var traffic: DeclarationTraffic = .{ .backing = memory.working.allocator() };
    const requests = try behavior.references.?(behavior.context, traffic.allocator(), input);
    try std.testing.expectEqual(ReferenceSizingProbe.saves, requests.len);
    try std.testing.expect(traffic.demand.allocations > requests.len + 1);
    const shared_bound = try hosting.references.allocationBound(0, requests.len, probe.uri.len);
    // Compare the scalar query with independently observed allocation traffic,
    // including every refused resize. Do not repeat ArrayList's growth formula.
    try std.testing.expect(bytes >= try std.math.add(usize, try shared_bound.physicalBytes(), try traffic.demand.physicalBytes()));
    @memset(&probe.uri, '!');
    for (requests) |request| {
        try std.testing.expect(request.save.uri.?.ptr != &probe.uri);
        try std.testing.expectEqualSlices(u8, &@as([4096]u8, @splat('x')), request.save.uri.?);
    }
}

fn checkOwnershipAndWorkers(backend: *n.GlowcapLoamLmdb, store: *c.GlowcapLoamStore, resource: c.GlowcapLoamResource) !void {
    const seed: [64]u8 = @splat(8);
    var host: ?*h.GlowcapHost = null;
    try std.testing.expectEqual(shared.GLOWCAP_OK, h.glowcap_host_new(&seed, seed.len, 4096, 1, shared.GLOWCAP_CODEC_SYRUP, shared.GLOWCAP_CAPTP_V1_0, shared.GLOWCAP_FEATURE_FULL, 0, &host));
    const continuations = @import("loam_continuations.zig");
    var continuation_probe: continuations.Probe = .{ .host = host.? };
    const methods = continuations.methods;
    const contents = [_]c.GlowcapLoamContent{.{ .schema = 7, .version = 1, .context = &continuation_probe, .methods = &methods, .method_count = methods.len, .requirement = requirements, .dependent_requirement = requirements, .invoke = continuations.Probe.invoke }};
    var attachment: ?*c.GlowcapLoamAttachment = null;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_attach(store, host, &contents, contents.len, entropy, null, &attachment));
    try std.testing.expectEqual(shared.GLOWCAP_ERR_INVALID_ARGUMENT, h.glowcap_host_release(host));
    try std.testing.expectEqual(shared.GLOWCAP_ERR_WOULD_BLOCK, n.glowcap_loam_lmdb_release(backend));
    var ref: shared.GlowcapReference = undefined;
    try std.testing.expectEqual(shared.GLOWCAP_OK, n.glowcap_loam_lmdb_restore(backend, attachment, &resource.use, &ref));
    const owner = try c.embedding.attachment(attachment);
    try @import("loam_limits.zig").check(owner, ref, resource.use, backend);
    try @import("loam_vocabulary.zig").check(&owner.service);
    try checkSaveQuota(owner, ref);
    continuation_probe.source = ref;
    try continuations.check(owner, backend, &continuation_probe);
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

fn checkSaveQuota(owner: *c.embedding.Attachment, reference: shared.GlowcapReference) !void {
    const refs = @import("loam_hosting").references;
    var saves: [96]*refs.Save = undefined;
    var count: usize = 0;
    defer for (saves[0..count]) |save| save.deinit();
    const held = owner.value.host.capabilityFromRaw(reference.id);
    for (&saves) |*save| {
        save.* = try refs.beginSave(owner.value, std.testing.allocator, held, null);
        count += 1;
        try std.testing.expect(save.*.result() == .ready);
    }
    // Completed proofs still own custody and count against the configured
    // ceiling. The former unprojected default refused the 65th proof.
    const refused = refs.beginSave(owner.value, std.testing.allocator, held, null);
    defer if (refused) |save| save.deinit() else |_| {};
    try std.testing.expectError(error.ReferenceCapacity, refused);
}

test "Loam C validates managed and save capacities before opening storage" {
    const schema: c.GlowcapLoamSchema = .{ .id = 7, .version = 1, .max_payload = 256, .max_edges = 8 };
    const schemas: [*]const c.GlowcapLoamSchema = @ptrCast(&schema);
    var limits: c.GlowcapLoamLimits = .{ .resident_bytes = 4 * 1024 * 1024, .staging_bytes = 4 * 1024 * 1024, .cache_slots = 64, .max_leases = 128, .max_changes = 64, .max_references = 128, .max_operations = 32 };
    limits.record_capacity = 0;
    try std.testing.expectEqual(shared.GLOWCAP_ERR_INVALID_ARGUMENT, c.glowcap_loam_validate_configuration(schemas, 1, &limits));
    limits.record_capacity = limits.max_leases - 1;
    try std.testing.expectEqual(shared.GLOWCAP_ERR_INVALID_ARGUMENT, c.glowcap_loam_validate_configuration(schemas, 1, &limits));
    limits.record_capacity = limits.max_leases - 2;
    limits.max_reference_saves = 0;
    try std.testing.expectEqual(shared.GLOWCAP_ERR_INVALID_ARGUMENT, c.glowcap_loam_validate_configuration(schemas, 1, &limits));
    limits.max_reference_saves = 96;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_validate_configuration(schemas, 1, &limits));
    limits.max_retentions = 0;
    try std.testing.expectEqual(shared.GLOWCAP_ERR_INVALID_ARGUMENT, c.glowcap_loam_validate_configuration(schemas, 1, &limits));
    limits.max_retentions = 256;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_validate_configuration(schemas, 1, &limits));
    limits.record_bytes = 0;
    try std.testing.expectEqual(shared.GLOWCAP_ERR_INVALID_ARGUMENT, c.glowcap_loam_validate_configuration(schemas, 1, &limits));
    limits.record_bytes = limits.resident_bytes + 1;
    try std.testing.expectEqual(shared.GLOWCAP_ERR_INVALID_ARGUMENT, c.glowcap_loam_validate_configuration(schemas, 1, &limits));
    limits.record_bytes = 128 * 1024;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_validate_configuration(schemas, 1, &limits));
    limits.forward_reply_bytes = 0;
    try std.testing.expectEqual(shared.GLOWCAP_ERR_INVALID_ARGUMENT, c.glowcap_loam_validate_configuration(schemas, 1, &limits));
    limits.forward_reply_bytes = std.math.maxInt(usize);
    try std.testing.expect(c.glowcap_loam_validate_configuration(schemas, 1, &limits) != shared.GLOWCAP_OK);
    limits.forward_reply_bytes = 3072;
    limits.max_continuations = 0;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_validate_configuration(schemas, 1, &limits));
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

const BindingProbe = struct {
    sizing: ReferenceSizingProbe = .{},
    calls: usize = 0,
    resource: ?c.GlowcapLoamBoundResource = null,
    delivery: u32 = 0,
    fn declare(context: ?*anyopaque, raw: *c.GlowcapLoamReferences, input: *const c.GlowcapLoamInvocation) callconv(.c) i32 {
        const self: *BindingProbe = @ptrCast(@alignCast(context.?));
        return ReferenceSizingProbe.declare(&self.sizing, raw, input);
    }
    fn requirement(context: ?*anyopaque, input: *const c.GlowcapLoamInvocation, out: *c.GlowcapLoamRequirement) callconv(.c) i32 {
        const self: *BindingProbe = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        self.resource = input.bound_resource;
        self.delivery = input.delivery;
        out.* = std.mem.zeroes(c.GlowcapLoamRequirement);
        return shared.GLOWCAP_OK;
    }
};
fn checkCallbackBinding(store: *c.GlowcapLoamStore, content_id: @import("loam_core").ObjectId, managed: @import("loam_access").records.ResourceRecord, object: @import("loam_core").ObjectId) !void {
    const access = @import("loam_access");
    const seed: [64]u8 = @splat(8);
    var host: ?*h.GlowcapHost = null;
    try std.testing.expectEqual(shared.GLOWCAP_OK, h.glowcap_host_new(&seed, seed.len, 4096, 1, shared.GLOWCAP_CODEC_SYRUP, shared.GLOWCAP_CAPTP_V1_0, shared.GLOWCAP_FEATURE_FULL, 0, &host));
    defer std.debug.assert(h.glowcap_host_release(host) == shared.GLOWCAP_OK);
    var probe: BindingProbe = .{};
    const methods = [_]c.GlowcapLoamMethod{.{ .verb = "get", .verb_len = 3, .retry = 0 }};
    const contents = [_]c.GlowcapLoamContent{.{ .schema = 7, .version = 1, .context = &probe, .methods = &methods, .method_count = 1, .requirement = BindingProbe.requirement, .invoke = invoke, .references = BindingProbe.declare }};
    var attachment: ?*c.GlowcapLoamAttachment = null;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_attach(store, host, &contents, 1, entropy, null, &attachment));
    defer std.debug.assert(c.glowcap_loam_attachment_release(attachment) == shared.GLOWCAP_OK);
    const owner = try c.embedding.store(store);
    const lease = (try owner.value.acquire(content_id)).ready;
    defer owner.value.release(lease) catch unreachable;
    const view = try owner.value.view(lease);
    const behavior = (try c.embedding.attachment(attachment)).content_behaviors[0];
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var input: access.hosting.ContentInvocation = .{ .bound_resource = .{ .id = managed.resource.id, .kind = managed.resource.kind, .object = object, .revision = managed.revision }, .delivery = .local, .content = view, .verb = "get", .args = &.{} };
    const driver = @import("driver_core");
    const Live = struct {
        pub fn handle(_: *@This(), _: *driver.HostTurn, _: []const u8, _: []const driver.Value) !driver.Value {
            return .{ .void = {} };
        }
    };
    const core_host = (try c.embedding.attachment(attachment)).value.host;
    const held = try core_host.liftLocalActor(try core_host.vat.spawn(driver.Hosting(Live), .{ .inner = .{} }));
    defer core_host.releaseCapabilityTerminal(held, null);
    probe.sizing.reference = .{ .id = held.raw() };
    try checkReferenceSizing(behavior, &probe.sizing, input);
    _ = try behavior.requirement(behavior.context, arena.allocator(), input);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(managed.resource.id.slot, probe.resource.?.id.slot);
    try std.testing.expectEqual(managed.resource.id.generation, probe.resource.?.id.generation);
    try std.testing.expectEqual(@backingInt(managed.resource.kind), probe.resource.?.kind);
    try std.testing.expectEqualDeep(c.embedding.objectToC(object), probe.resource.?.object);
    try std.testing.expectEqual(@as(u32, 0), probe.delivery);
    input.delivery = .forwarding;
    _ = try behavior.requirement(behavior.context, arena.allocator(), input);
    try std.testing.expectEqual(@as(u32, 1), probe.delivery);
    input.bound_resource.object = view.id;
    try std.testing.expectError(error.InvalidRecord, behavior.requirement(behavior.context, arena.allocator(), input));
    try std.testing.expectEqual(@as(usize, 2), probe.calls);
}

test "Loam C maximum prepared graph projection matches its logical allowance" {
    const projection = c.embedding.graph_projection;
    const graph = @import("loam_access").hosting.graph;
    // This is a projection-cost witness. Hosted graph tests own page admission
    // and reference semantics; these views supply already prepared borrows.
    const page_count = 63;
    const field_count = 3592;
    const payload_bytes = 1024 * 1024;
    var fixture: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer fixture.deinit();
    const payload = try fixture.allocator().alloc(u8, payload_bytes);
    @memset(payload, 'x');
    const pages = try fixture.allocator().alloc(graph.Page, page_count);
    var offset: usize = 0;
    for (pages, 0..) |*page, index| {
        const length: usize = payload_bytes / page_count + @as(usize, @intFromBool(index < payload_bytes % page_count));
        page.* = .{ .view = .{
            .id = .{ .store = @fromBackingInt(1), .incarnation = 1, .sequence = index + 1 },
            .revision = 1,
            .schema = 7,
            .schema_version = 1,
            .rooted = false,
            .payload = payload[offset..][0..length],
            .edge_bytes = &.{},
            .edge_count = 1 + field_count / page_count + @as(usize, @intFromBool(index < field_count % page_count)),
        } };
        offset += length;
    }
    const Bound = @import("loam_hosting").references.AllocationBound;
    var owned: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer owned.deinit();
    var traffic: @import("support_alloc_metrics").AllocationTraffic(Bound) = .{ .backing = owned.allocator() };
    for (0..3) |_| {
        const projected = try projection.project(traffic.allocator(), .{ .pages = pages });
        var fields: usize = 0;
        var bytes: usize = 0;
        for (projected, pages) |page, *source| {
            try std.testing.expectEqual(@as(@TypeOf(page.handle), @ptrCast(source.handle())), page.handle);
            try std.testing.expectEqual(source.view.payload.ptr, page.payload);
            fields += page.field_count;
            bytes += page.payload_len;
        }
        try std.testing.expectEqual(field_count, fields);
        try std.testing.expectEqual(payload_bytes, bytes);
    }
    const bound = try projection.projectionAllocationBound(page_count);
    try std.testing.expectEqual(bound.bytes, traffic.demand.bytes);
    try std.testing.expectEqual(bound.allocations, traffic.demand.allocations);
}
