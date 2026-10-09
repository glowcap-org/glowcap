//! A deterministic record-backed counter and an ordinary Host for Loam tests.
const std = @import("std");
const glowcap = @import("glowcap");
const records = @import("../core/fixture.zig");
const host_support = @import("../../support/core_host.zig");
pub const loam = glowcap.loam;
pub const hosting = loam.hosting;
pub const driver = glowcap.driver.core;
pub const actors = glowcap.actors;
pub const schemas = records.schemas ++ [_]loam.core.Schema{hosting.publication.schema};
pub const behaviors = [_]hosting.Behavior{.{ .schema = 7, .invoke = counter }};

pub fn counter(call: *hosting.Call, view: loam.core.RecordView, verb: []const u8, args: []const driver.Value) !driver.Value {
    if (view.payload.len != 8) return error.InvalidPortrait;
    const number = std.mem.readInt(i64, view.payload[0..8], .little);
    if (std.mem.eql(u8, verb, "get")) return .{ .integer = number };
    if (std.mem.eql(u8, verb, "edge")) return .{ .capability = try call.edge(0) };
    if (std.mem.eql(u8, verb, "add") or std.mem.eql(u8, verb, "fail")) {
        if (args.len != 1 or args[0] != .integer) return error.InvalidArguments;
        const next = try std.math.add(i64, number, args[0].integer);
        const bytes = try call.arena().alloc(u8, 8);
        std.mem.writeInt(i64, bytes[0..8], next, .little);
        call.replace(bytes);
        if (std.mem.eql(u8, verb, "fail")) return error.Refused;
        return .{ .integer = next };
    }
    return error.NoSuchMethod;
}

pub const Capture = struct {
    value: ?i64 = null,
    broken: bool = false,
    pub fn record(ctx: ?*anyopaque, result: actors.Resolution) void {
        const self: *Capture = @ptrCast(@alignCast(ctx.?));
        switch (result) {
            .fulfilled => |value| self.value = value.integer,
            else => self.broken = true,
        }
    }
};

pub const Fixture = struct {
    data: records.Fixture,
    host: driver.Host,
    attached: *hosting.Attachment,
    root: driver.Capability,
    id: loam.core.ObjectId,

    pub fn init(self: *Fixture, options: hosting.Options) !void {
        return self.initAllocator(std.testing.allocator, options);
    }

    pub fn initAllocator(self: *Fixture, allocator: std.mem.Allocator, options: hosting.Options) !void {
        self.data.backend = try loam.Volatile.init(allocator, records.id, 1024 * 1024);
        errdefer self.data.backend.deinit();
        self.data.store = try loam.core.Store.init(allocator, try self.data.backend.open(), &schemas, records.limits);
        errdefer self.data.store.deinit() catch unreachable;
        self.host = host_support.init(allocator, @splat(0x71), driver.Host.Options.withFrameCap(4096));
        errdefer self.host.deinit();
        try self.data.store.begin();
        errdefer if (self.data.store.phase == .staging or self.data.store.phase == .prepared) self.data.store.abort() catch unreachable;
        self.id = try self.data.store.allocateId();
        var record = records.record(self.id, &@as([8]u8, @splat(0)));
        record.rooted = true;
        try self.data.store.putCopying(record, null);
        try records.commit(&self.data.store, &self.data.backend);
        self.attached = try hosting.Attachment.create(allocator, &self.host, &self.data.store, &behaviors, options);
        errdefer self.attached.destroy() catch unreachable;
        const lease = try records.load(&self.data.store, &self.data.backend, self.id);
        defer self.data.store.release(lease) catch unreachable;
        self.root = try self.attached.restore(lease);
    }

    pub fn deinit(self: *Fixture) void {
        self.host.releaseCapability(self.root, 1) catch unreachable;
        self.attached.destroy() catch unreachable;
        self.host.deinit();
        self.data.deinit();
    }

    pub fn send(self: *Fixture, verb: []const u8, args: []const glowcap.ocapn.model.Argument, capture: *Capture) !void {
        const ref = self.host.localActorFor(self.root).?;
        _ = try self.host.vat.sendObservedFromIngress(.local, ref, .{ .verb = verb, .args = args }, .{ .ctx = capture, .func = Capture.record });
    }

    pub fn drain(self: *Fixture) !void {
        for (0..64) |_| {
            _ = try self.host.vat.driveIngressBudgeted(.local, 64);
            try self.attached.advance();
            while (try self.attached.nextWork()) |work| switch (work) {
                .read => |request| try self.attached.completeRead(request.ticket, self.data.backend.read(request)),
                .lookup => |request| try self.attached.completeLookup(request.ticket, self.data.backend.lookup(request)),
                .write => |batch| try self.attached.completeWrite(batch.ticket, self.data.backend.commit(batch)),
            };
            if (!self.attached.hasPendingWork()) return;
        }
        return error.DidNotQuiesce;
    }
};
