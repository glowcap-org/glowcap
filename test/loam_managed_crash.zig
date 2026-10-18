//! Process-loss proof for managed issuance, control, content, and reference edits.
//! The Python supervisor SIGKILLs this process at an acknowledged boundary.
//! Verification starts a new Host and Store and fetches only durable names.
//! Validated against omitted source receipt persistence, stale event linkage,
//! and ignored revocation. This exercises synchronous process loss, not
//! power loss or cross-vat restoration.
const std = @import("std");
const h = @import("loam/access/hosting_fixture.zig");
const management = @import("loam/access/management_fixture.zig");
const resources = @import("loam/access/resource_fixture.zig");
const sharing = @import("loam/access/sharing_fixture.zig");
const pairs = @import("support/host_pair.zig");
const captures = @import("support/capture.zig");
const fixture = @import("engine_fixture");
const core = h.loam.core;
const records = h.loam.access.records;
const publication = h.loam.hosting.publication;
const model = h.f.glowcap.ocapn.model;
const use_entropy: publication.Entropy = @splat(0x41);
const control_entropy: publication.Entropy = @splat(0x42);
const observation = @import("loam/access/observation_process.zig");
const wire = @import("support/storage_host_pair.zig");
const send = wire.send;
const fetch = wire.fetch;
const maintenance = @import("loam/access/maintenance_process.zig");
const schemas = h.schemas ++ [_]core.Schema{ observation.schema, maintenance.schema };
const Scenario = enum { derive, managed, attenuate, revoke, add, remove, move, delete, observe, cancel, retire, cleanup };
const Boundary = enum { before, after, installed, published };
extern "c" fn pause() c_int;

pub fn main(init: std.process.Init) !void {
    const args = init.minimal.args.vector;
    if (args.len != 4) return error.InvalidArguments;
    const mode = std.mem.span(args[1]);
    const scenario = std.meta.stringToEnum(Scenario, std.mem.span(args[3])) orelse return error.InvalidArguments;
    const creating = std.mem.eql(u8, mode, "create");
    const verifying = std.mem.eql(u8, mode, "verify-old") or std.mem.eql(u8, mode, "verify-new");
    const boundary = if (creating or verifying) null else std.meta.stringToEnum(Boundary, mode) orelse return error.InvalidArguments;
    var db = try fixture.open(std.mem.span(args[2]), if (creating) .create else .open, h.f.store_id);
    defer db.close() catch unreachable;
    var store = try core.Store.init(init.gpa, db.metadata, &schemas, h.limits);
    defer store.deinit() catch unreachable;
    var server: Server = undefined;
    try server.init(&store, &db, init.io);
    defer server.deinit();
    if (creating) {
        const data = if (scenario == .move or scenario == .delete) (try resources.seed(&store, &db)).data else try h.seedDepth(&store, &db, 1);
        if (scenario == .move) _ = try h.f.resource(&store, &db, data.owner, .{ .owner = data.resource.owner, .slot = 0, .generation = 1 });
        const use_lease = try h.c.load(&store, &db, data.use);
        defer store.release(use_lease) catch unreachable;
        const control_lease = try h.c.load(&store, &db, data.control);
        defer store.release(control_lease) catch unreachable;
        try store.begin();
        _ = try h.access.stagePublication(&store, use_lease, use_entropy);
        _ = try h.access.stagePublication(&store, control_lease, control_entropy);
        try h.f.commit(&store, &db);
        if (scenario == .cancel) {
            var client = h.host_support.init(init.gpa, @splat(0x63), h.driver.Host.Options.withFrameCap(4096));
            defer client.deinit();
            const pair = try pairs.openPair(&client, &server.host, "127.0.0.1:9732");
            const use = try fetch(&server, &client, pair, use_entropy);
            try observation.createWitness(&server, &client, pair, use, data.owner);
        }
        if (scenario == .retire or scenario == .cleanup) {
            var client = h.host_support.init(init.gpa, @splat(0x63), h.driver.Host.Options.withFrameCap(4096));
            defer client.deinit();
            const pair = try pairs.openPair(&client, &server.host, "127.0.0.1:9732");
            const use = try fetch(&server, &client, pair, use_entropy);
            try maintenance.create(&server, &client, pair, use, data.owner, scenario == .cleanup);
        }
        return;
    }
    // Startup does not need an inventory of owner, grant, or endpoint IDs.
    if (store.cache.allocated_bytes != 0 or server.host.publications.count() != 0) return error.EagerRestore;
    for (server.attached.entries) |entry| if (entry.actor != null) return error.EagerRestore;
    var client = h.host_support.init(init.gpa, @splat(0x63), h.driver.Host.Options.withFrameCap(4096));
    defer client.deinit();
    const pair = try pairs.openPair(&client, &server.host, "127.0.0.1:9732");
    const use = try fetch(&server, &client, pair, use_entropy);
    const control = try fetch(&server, &client, pair, control_entropy);
    if (verifying) {
        try verify(&server, &client, pair, use, control, scenario, std.mem.eql(u8, mode, "verify-new"));
        return;
    }
    // A positive read calibrates the recovered capability before the mutation.
    var initial: h.Answer = .{};
    try send(&client, pair, use, "get", &.{}, &initial);
    try server.drain();
    try pairs.pumpToQuiescence(&.{pair});
    if (initial.number != 0 or initial.broken) return error.InvalidInitialState;
    var reply: Reply = .{};
    const target = if (scenario == .retire or scenario == .cleanup) try fetch(&server, &client, pair, maintenance.admin_name) else if (scenario == .cancel) try observation.canceller(&server, &client, pair) else if (scenario == .revoke or scenario == .attenuate) control else use;
    const verb = switch (scenario) {
        .derive => "derive",
        .managed => "derive-managed",
        .attenuate => "mutate",
        .revoke => "revoke",
        .add => "mutate",
        .remove, .move, .delete, .observe => "mutate",
        .cancel => "cancel",
        .retire => "retire-owner",
        .cleanup => "maintenance-step",
    };
    const arguments: []const model.Argument = switch (scenario) {
        .derive => &.{ .{ .integer = 1 }, .{ .integer = 0 }, .{ .integer = 0 } },
        .managed => &.{ .{ .integer = 1 }, .{ .integer = 0 }, .{ .integer = 0 }, .{ .integer = 7 } },
        .attenuate => &.{ .{ .integer = 1 }, .{ .string = "attenuate-control" }, .{ .integer = 1 } },
        .add => &.{ .{ .integer = 1 }, .{ .string = "add" }, .{ .integer = 5 } },
        .remove => &.{ .{ .integer = 1 }, .{ .string = "remove-reference" } },
        .move => &.{ .{ .integer = 1 }, .{ .string = "move-resource" }, .{ .integer = 3 } },
        .delete => &.{ .{ .integer = 1 }, .{ .string = "delete-resource" } },
        .observe => &.{ .{ .integer = 1 }, .{ .string = "observe" } },
        .retire, .cleanup => &.{.{ .integer = @intCast(try maintenance.sequence(&server)) }},
        else => &.{},
    };
    try send(&client, pair, target, verb, arguments, &reply);
    const batch = try server.untilWrite();
    try pairs.pumpToQuiescence(&.{pair});
    if (reply.settled) return error.PrematureReply;
    if (scenario == .derive or scenario == .managed) {
        const name = h.driver.Host.DurableSwiss.fromEntropy(server.last_entropy);
        if (try server.host.publishedCapability(pair.b, name.slice())) |early| {
            try server.host.releaseCapability(early, 1);
            return error.PrematurePublication;
        }
    }
    var observation_names: [2]publication.Entropy = undefined;
    if (scenario == .observe) {
        var count: usize = 0;
        for (batch.changes) |change| if (change.bytes) |bytes| {
            const view = try core.RecordView.decode(bytes, store.limits.records, &schemas);
            if (view.schema == publication.schema.id) {
                if (count == observation_names.len) return error.DuplicateObservation;
                observation_names[count] = view.payload[0..16].*;
                const name = h.driver.Host.DurableSwiss.fromEntropy(observation_names[count]);
                if ((try server.host.publishedCapability(pair.b, name.slice())) != null) return error.PrematurePublication;
                count += 1;
            }
        };
        if (count != observation_names.len) return error.MissingPublication;
    }
    var pending = try db.beginWrite();
    const next = try batch.apply(&pending);
    if (boundary.? == .before) stop();
    if (try pending.commit() != .committed) return error.CommitFailed;
    const outcome: h.loam.core.Outcome = .{ .committed = next };
    if (boundary.? == .after) stop();
    try server.attached.completeWrite(batch.ticket, outcome);
    if (boundary.? == .installed) stop();
    // Confirmation activates the reserved publication and queues the reply.
    // Do not deliver outbound frames: the caller cannot have seen that reply.
    try server.drain();
    if (reply.settled) return error.PrematureReply;
    if (scenario == .derive or scenario == .managed) {
        const name = h.driver.Host.DurableSwiss.fromEntropy(server.last_entropy);
        const published = (try server.host.publishedCapability(pair.b, name.slice())) orelse return error.PublicationNotInstalled;
        try server.host.releaseCapability(published, 1);
    }
    if (scenario == .observe) for (observation_names) |secret| {
        const name = h.driver.Host.DurableSwiss.fromEntropy(secret);
        const held = (try server.host.publishedCapability(pair.b, name.slice())) orelse return error.PublicationNotInstalled;
        try server.host.releaseCapability(held, 1);
    };
    var outbound = (try pair.b.takeOutbound()) orelse return error.ReplyNotQueued;
    outbound.deinit();
    stop();
}

fn stop() noreturn {
    std.debug.print("READY\n", .{});
    while (true) _ = pause();
}

const Reply = struct {
    settled: bool = false,
    pub fn record(context: ?*anyopaque, _: h.actors.Resolution) void {
        const self: *Reply = @ptrCast(@alignCast(context.?));
        self.settled = true;
    }
};

const Server = struct {
    host: h.driver.Host,
    caps: h.c.storage.Capabilities,
    service: h.access.Service,
    behaviors: [h.access.Service.behavior_count]h.loam.hosting.Behavior,
    attached: *h.loam.hosting.Attachment,
    db: *fixture.Engine,
    io: std.Io,
    last_entropy: publication.Entropy = @splat(0),

    fn init(self: *Server, store: *core.Store, db: *fixture.Engine, io: std.Io) !void {
        self.host = h.host_support.init(store.allocator, @splat(0x61), h.driver.Host.Options.withFrameCap(4096));
        self.caps = try h.c.storage.Capabilities.init(store.allocator, store, .{});
        self.service = .{
            .capabilities = &self.caps,
            .contents = &h.contents,
            .record_capacity = 8,
            .decode_derive = sharing.decode,
            .decode_managed_derive = management.decodeManaged,
            .decode_attenuation = management.decodeAttenuation,
            .entropy = .{ .context = self, .fill = entropy },
        };
        self.behaviors = self.service.behaviors();
        self.attached = try h.loam.hosting.Attachment.create(store.allocator, &self.host, store, &self.behaviors, .{ .sleep_policy = .every_turn });
        self.db = db;
        self.io = io;
        self.last_entropy = @splat(0);
        try publication.listen(self.attached, .{});
    }

    fn deinit(self: *Server) void {
        self.attached.destroy() catch unreachable;
        self.host.deinit();
        self.caps.deinit() catch unreachable;
    }

    fn entropy(context: ?*anyopaque, bytes: *publication.Entropy) !void {
        const self: *Server = @ptrCast(@alignCast(context.?));
        // Distinct process restarts need distinct proposed names. Receipt replay
        // must return the committed name, never this fresh entropy.
        std.Io.random(self.io, bytes);
        self.last_entropy = bytes.*;
    }

    fn progress(self: *Server) !?core.Batch {
        try self.attached.advance();
        while (try self.attached.nextWork()) |work| switch (work) {
            .lookup => |request| try self.attached.completeLookup(request.ticket, self.db.lookup(request)),
            .read => |request| try self.attached.completeRead(request.ticket, self.db.read(request)),
            .write => |batch| return batch,
        };
        return null;
    }

    fn untilWrite(self: *Server) !core.Batch {
        for (0..256) |_| if (try self.progress()) |batch| return batch;
        return error.DidNotWrite;
    }

    pub fn drain(self: *Server) !void {
        for (0..256) |_| {
            if (try self.progress()) |batch| try self.attached.completeWrite(batch.ticket, self.db.commit(batch));
            if (!self.attached.hasPendingWork()) return;
        }
        return error.DidNotQuiesce;
    }
};

/// Trusted inspection follows the same immutable name index as discovery. Only
/// wire calls below establish restored capability authority. IDs never do.
fn endpoint(server: *Server, secret: publication.Entropy) !records.EndpointRecord {
    const store = server.caps.store;
    const result = server.db.lookup(.{
        .ticket = .{ .store = store.metadata.store, .incarnation = store.metadata.incarnation, .revision = store.metadata.revision, .sequence = 1 },
        .name = .{ .schema = publication.schema.id, .bytes = secret },
    });
    const id = switch (result) {
        .found => |id| id,
        .failed => |err| return err,
        .missing => return error.MissingPublication,
    };
    const lease = try h.c.load(store, server.db, id);
    const target = try publication.activeTarget(try store.currentView(lease));
    try store.release(lease);
    const target_lease = try h.c.load(store, server.db, target);
    defer store.release(target_lease) catch unreachable;
    return records.EndpointRecord.decode(try store.currentView(target_lease));
}

fn verify(server: *Server, client: *h.driver.Host, pair: pairs.Pair, use: model.Reference, control: model.Reference, scenario: Scenario, committed: bool) !void {
    if (scenario == .retire or scenario == .cleanup) return maintenance.verify(server, client, pair, use, scenario == .cleanup, committed);
    const store = server.caps.store;
    const parent = try endpoint(server, use_entropy);
    const descriptor_lease = try h.c.load(store, server.db, parent.descriptor);
    var descriptor: records.CapabilityRecord = undefined;
    try descriptor.decodeOwned(store.allocator, try store.currentView(descriptor_lease));
    defer descriptor.deinit(store.allocator);
    try store.release(descriptor_lease);
    var read: h.c.storage.Read = undefined;
    try read.init(store.allocator, store, descriptor.owner, 8, null);
    defer read.deinit() catch unreachable;
    _ = try h.f.pump(&read, server.db);
    if (scenario == .observe or scenario == .cancel) {
        try observation.verify(server, client, pair, use, descriptor.owner, scenario == .cancel, committed);
        return;
    }
    const derived = (scenario == .derive or scenario == .managed) and committed;
    if (read.header.next_grant != (if (derived) @as(u64, 2) else 1) or parent.derivations.count != @intFromBool(derived) or parent.derivations.next != (if (derived) @as(u64, 2) else 1)) return error.NonAtomicIssuance;
    const event = try h.f.latestGrant(&read, server.db);
    const latest = read.history.batches[read.history.count - 1];
    const retained_lease = try h.c.load(store, server.db, latest);
    var retained: records.ChangeBatchRecord = undefined;
    try retained.decodeOwned(store.allocator, try store.currentView(retained_lease));
    defer retained.deinit(store.allocator);
    try store.release(retained_lease);
    const effects = retained.effects;
    if (retained.sequence != read.history.next_sequence - 1 or retained.commit_revision > store.metadata.revision) return error.NonAtomicHistory;
    if (committed) switch (scenario) {
        .derive, .managed, .revoke => if (effects.len != 1 or effects[0] != .grant) return error.WrongRetainedEffect,
        .attenuate => if (effects.len != 1 or effects[0] != .control) return error.WrongRetainedEffect,
        .add, .remove => if (effects.len != 1 or effects[0] != .content) return error.WrongRetainedEffect,
        .observe, .cancel, .retire, .cleanup => unreachable,
        .move, .delete => if (effects.len != 2 or effects[0] != .resource or effects[1] != .content) return error.WrongRetainedEffect,
    } else {
        if (effects.len != 1) return error.WrongRetainedEffect;
        if (scenario == .move) {
            if (effects[0] != .resource or effects[0].resource.kind != .created or effects[0].resource.id.slot != 3) return error.WrongRetainedEffect;
        } else if (effects[0] != .grant) return error.WrongRetainedEffect;
    }
    if (event.version.grants != read.header.version.grants or @backingInt(event.version.resources) > @backingInt(read.header.version.resources)) return error.NonAtomicEvent;
    if (scenario == .revoke and committed) {
        if (event.kind != .status_changed or event.kind.status_changed.before != .active or event.kind.status_changed.after != .revoked) return error.WrongEvent;
    } else if (event.kind != .issued) return error.WrongEvent;
    if (event.grant.owner != descriptor.grant.owner or event.grant.slot != descriptor.grant.slot + @intFromBool(derived)) return error.WrongEventTarget;
    const content_lease = try h.c.load(store, server.db, parent.content.?.object);
    const content = try store.currentView(content_lease);
    const expected_content: i64 = if (committed and scenario == .add) 5 else if (committed and (scenario == .move or scenario == .delete)) 1 else 0;
    if (std.mem.readInt(i64, content.payload[0..8], .little) != expected_content) return error.NonAtomicContent;
    if (content.edge_count != (if (scenario == .move or scenario == .delete) @as(usize, 0) else if (scenario == .remove and committed) @as(usize, 1) else 2)) return error.NonAtomicReference;
    try store.release(content_lease);

    if (scenario == .move or scenario == .delete) {
        var structure = try read.resourceView();
        const target = parent.content.?.resource;
        for (0..128) |_| {
            const current = structure.get(target) catch |err| {
                if (err == error.RecordUnloaded) {
                    _ = try h.f.pump(&read, server.db);
                    continue;
                }
                if (scenario == .delete and committed and err == error.Gone) break;
                return err;
            };
            if (scenario == .delete and committed) return error.DeletedResourceRestored;
            if (current.parent == null or current.parent.?.slot != (if (scenario == .move and committed) @as(u32, 3) else 0)) return error.NonAtomicResource;
            break;
        }
        if (parent.mutations.count != @intFromBool(committed)) return error.NonAtomicReceipt;
    }
    var get: h.Answer = .{};
    try send(client, pair, use, "get", &.{}, &get);
    try server.drain();
    try pairs.pumpToQuiescence(&.{pair});
    if (scenario == .revoke and committed) {
        if (!get.broken or !std.mem.eql(u8, get.reason(), "Revoked")) return error.RevokedAuthorityRestored;
    } else if (scenario == .delete and committed) {
        if (!get.broken or !std.mem.eql(u8, get.reason(), "Gone")) return error.StaleResourceAuthority;
    } else if (get.broken or get.number != expected_content) return error.InvalidRecoveredState;
    // Role restoration must not turn held use into management, or vice versa.
    for ([_]model.Reference{ use, control }, [_][]const u8{ "revoke", "get" }) |target, verb| {
        var wrong: h.Answer = .{};
        try send(client, pair, target, verb, &.{}, &wrong);
        try server.drain();
        try pairs.pumpToQuiescence(&.{pair});
        if (!wrong.broken) return error.WidenedRole;
    }
    if (scenario == .remove) {
        var shared: captures.CapturedRef = .{};
        try send(client, pair, use, "share", &.{}, &shared);
        try server.drain();
        try pairs.pumpToQuiescence(&.{pair});
        if (committed) {
            if (!shared.broken or !std.mem.eql(u8, shared.reason_buf[0..shared.reason_len], "NotDurable")) return error.RemovedReferenceRestored;
        } else {
            var saved: h.Answer = .{};
            try send(client, pair, try shared.require(), "get", &.{}, &saved);
            try server.drain();
            try pairs.pumpToQuiescence(&.{pair});
            if (saved.number != 0 or saved.broken) return error.AbortedReferenceLost;
        }
    }
    if (scenario == .add or scenario == .remove) {
        const revision = store.metadata.revision;
        var retry: h.Answer = .{};
        const args: []const model.Argument = if (scenario == .add) &.{ .{ .integer = 1 }, .{ .string = "add" }, .{ .integer = 5 } } else &.{ .{ .integer = 1 }, .{ .string = "remove-reference" } };
        try send(client, pair, use, "mutate", args, &retry);
        try server.drain();
        try pairs.pumpToQuiescence(&.{pair});
        if (retry.broken or (scenario == .add and retry.number != 5) or (scenario == .remove and retry.changed != true)) return error.InvalidRetry;
        if (store.metadata.revision != revision + @intFromBool(!committed)) return error.RepeatedEffect;
    }
    if (scenario == .managed or scenario == .attenuate) try verifyManagement(server, client, pair, use, control, scenario, committed);
    if (scenario == .derive) try verifyRetry(server, client, pair, use, parent, committed);
}

fn verifyRetry(server: *Server, client: *h.driver.Host, pair: pairs.Pair, parent_ref: model.Reference, parent: records.EndpointRecord, committed: bool) !void {
    const store = server.caps.store;
    var cold: ?model.Reference = null;
    if (committed) {
        const receipt_lease = try h.c.load(store, server.db, parent.derivations.receipts[0]);
        const receipt = try records.DerivationRecord.decode(try store.currentView(receipt_lease));
        const publication_id = receipt.publication;
        try store.release(receipt_lease);
        const published_lease = try h.c.load(store, server.db, publication_id);
        const secret = (try store.currentView(published_lease)).payload[0..16].*;
        try store.release(published_lease);
        // Fetch before retry. Receipt replay cannot hide a missing publication.
        cold = try fetch(server, client, pair, secret);
    }
    const revision = store.metadata.revision;
    var replay: captures.CapturedRef = .{};
    try send(client, pair, parent_ref, "derive", &.{ .{ .integer = 1 }, .{ .integer = 0 }, .{ .integer = 0 } }, &replay);
    try server.drain();
    try pairs.pumpToQuiescence(&.{pair});
    const child = try replay.require();
    if (store.metadata.revision != revision + @intFromBool(!committed)) return error.DuplicateIssuance;
    var value: h.Answer = .{};
    try send(client, pair, child, "get", &.{}, &value);
    try server.drain();
    try pairs.pumpToQuiescence(&.{pair});
    if (value.number != 0 or value.broken) return error.ChildNotCallable;
    var denied: h.Answer = .{};
    try send(client, pair, child, "add", &.{.{ .integer = 1 }}, &denied);
    try server.drain();
    try pairs.pumpToQuiescence(&.{pair});
    if (!denied.broken or !std.mem.eql(u8, denied.reason(), "Denied")) return error.WidenedChildAuthority;
    var conflict: captures.CapturedRef = .{};
    try send(client, pair, parent_ref, "derive", &.{ .{ .integer = 1 }, .{ .integer = 1 }, .{ .integer = 0 } }, &conflict);
    try server.drain();
    try pairs.pumpToQuiescence(&.{pair});
    if (!conflict.broken or !std.mem.eql(u8, conflict.reason_buf[0..conflict.reason_len], "OperationConflict")) return error.RetryIntentChanged;
    if (cold) |fetched| {
        const original = try client.liftCapability(pair.a, fetched);
        defer client.releaseCapability(original, 1) catch unreachable;
        const retried = try client.liftCapability(pair.a, child);
        defer client.releaseCapability(retried, 1) catch unreachable;
        if (!original.eql(retried)) return error.ChangedRetryAuthority;
    }
}

fn verifyManagement(server: *Server, client: *h.driver.Host, pair: pairs.Pair, use: model.Reference, control: model.Reference, scenario: Scenario, committed: bool) !void {
    const revision = server.caps.store.metadata.revision;
    var issued: management.Pair = .{};
    var attenuated: captures.CapturedRef = .{};
    if (scenario == .managed) {
        try send(client, pair, use, "derive-managed", &.{ .{ .integer = 1 }, .{ .integer = 0 }, .{ .integer = 0 }, .{ .integer = 7 } }, &issued);
    } else {
        try send(client, pair, control, "mutate", &.{ .{ .integer = 1 }, .{ .string = "attenuate-control" }, .{ .integer = 1 } }, &attenuated);
    }
    try server.drain();
    try pairs.pumpToQuiescence(&.{pair});
    const recovered = if (scenario == .managed) try issued.control.require() else try attenuated.require();
    if (server.caps.store.metadata.revision != revision + @intFromBool(!committed)) return error.RepeatedIssuance;
    var inspection: management.Inspection = .{};
    try send(client, pair, recovered, "describe-control", &.{}, &inspection);
    try server.drain();
    try pairs.pumpToQuiescence(&.{pair});
    if (inspection.available != true or inspection.fields != 10) return error.InvalidControlRecovery;
    var paused: h.Answer = .{};
    try send(client, pair, recovered, "pause", &.{}, &paused);
    try server.drain();
    try pairs.pumpToQuiescence(&.{pair});
    if (paused.changed != true) return error.InvalidRecoveredPower;
    var denied: h.Answer = .{};
    try send(client, pair, if (scenario == .managed) try issued.use.require() else use, "get", &.{}, &denied);
    try server.drain();
    try pairs.pumpToQuiescence(&.{pair});
    if (!denied.broken or !std.mem.eql(u8, denied.reason(), "Paused")) return error.WrongControlTarget;
}
