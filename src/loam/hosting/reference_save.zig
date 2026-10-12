//! Saving proves a recipe names the capability held by the caller.
//! Host owns all remote restoration. Local capture requires no networking.
const std = @import("std");
const model = @import("model");
const core = @import("loam_core");
const driver = @import("driver_core");
const h = @import("attachment.zig");
const Recipe = @import("reference_recipe.zig").Recipe;
pub const max_uri_bytes = @import("reference_recipe.zig").schema.max_payload - 1;

pub fn allocationBound(count: usize, uri_bytes: usize) !@import("call_memory.zig").AllocationBound {
    var bound: @import("call_memory.zig").AllocationBound = .{};
    try bound.include(@sizeOf(State), @alignOf(State), count);
    try bound.include(@max(try Save.canonicalUriBytesBound(uri_bytes), @import("reference_scope.zig").Scope.max_name_bytes), 1, count);
    try bound.include(@sizeOf(driver.Host.Enliven), @alignOf(driver.Host.Enliven), count);
    return bound;
}

pub const Save = opaque {
    pub const Result = union(enum) { pending, ready, failed: anyerror };

    /// Accepted input bytes can expand to three-byte percent escapes. The
    /// recipe limit independently refuses larger canonical output.
    pub fn canonicalUriBytesBound(supplied_bytes: usize) !usize {
        if (supplied_bytes > max_uri_bytes) return error.RecordTooLarge;
        return @min(max_uri_bytes, try std.math.mul(usize, supplied_bytes, 3));
    }

    pub fn result(self: *Save) Result {
        return state(self).result();
    }
    pub fn deinit(self: *Save) void {
        state(self).deinit();
    }
};

pub fn state(save: *Save) *State {
    return @ptrCast(@alignCast(save));
}

const State = struct {
    owner: *h.Attachment,
    allocator: std.mem.Allocator,
    capability: driver.Capability,
    recipe: union(enum) { edge: core.Edge, recipe: Recipe },
    bytes: ?[]u8 = null,
    enliven: ?*driver.Host.Enliven = null,
    state: union(enum) { pending, ready, failed: anyerror },

    const Result = Save.Result;

    /// Borrow the operation's validated recipe state. Readiness proves exact
    /// identity, not current remote permission or future availability.
    pub fn result(self: *State) Result {
        if (self.state == .pending) switch (self.enliven.?.result()) {
            .pending => {},
            .failed => self.state = .{ .failed = error.RestorationFailed },
            .ready => |ready| {
                const target = self.owner.host.settledCapability(self.capability) catch |err| {
                    self.state = .{ .failed = err };
                    return .{ .failed = err };
                };
                self.state = if (ready.capability.eql(target)) .ready else .{ .failed = error.DurableReferenceMismatch };
            },
        };
        return switch (self.state) {
            .pending => .pending,
            .ready => .ready,
            .failed => |err| .{ .failed = err },
        };
    }

    pub fn deinit(self: *State) void {
        self.owner.host.refuseReentry() catch unreachable;
        if (self.enliven) |enliven| enliven.deinit();
        self.owner.host.releaseCapabilityTerminal(self.capability, null);
        if (self.bytes) |bytes| self.allocator.free(bytes);
        std.debug.assert(self.owner.reference_saves != 0);
        self.owner.reference_saves -= 1;
        self.allocator.destroy(self);
    }
};

/// Save a local held target immediately, or validate an already established
/// foreign sturdy URI through Host enlivenment. A live-only target has no
/// durable recipe. This operation must retire before its attachment closes.
pub fn begin(owner: *h.Attachment, allocator: std.mem.Allocator, capability: driver.Capability, uri: ?[]const u8) !*Save {
    try owner.topLevel();
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    return beginPrepared(owner, allocator, scratch.allocator(), capability, uri, null);
}

/// Internal preparation at a top-level Host boundary inside Attachment.advance.
pub fn beginPrepared(owner: *h.Attachment, allocator: std.mem.Allocator, scratch: std.mem.Allocator, capability: driver.Capability, uri: ?[]const u8, work: ?*const driver.Host.PendingWorkLease) !*Save {
    try owner.host.refuseReentry();
    if (work) |lease| try lease.checkHost(owner.host);
    if (owner.closing) return error.AttachmentClosed;
    const target = try owner.host.settledCapability(capability);
    if (owner.reference_saves >= owner.options.max_reference_saves) return error.ReferenceCapacity;
    owner.reference_saves += 1;
    errdefer owner.reference_saves -= 1;
    const self = try allocator.create(State);
    errdefer allocator.destroy(self);
    const retains = try owner.host.retainValueCapabilities(scratch, &.{.{ .capability = capability }});
    errdefer owner.host.releaseUntransferredCapabilityRetains(retains);
    if (owner.capture(target)) |edge| {
        self.* = .{ .owner = owner, .allocator = allocator, .capability = retains[0].ref, .recipe = .{ .edge = edge }, .state = .ready };
        return @ptrCast(self);
    } else |err| if (err != error.NotDurable) return err;
    if (owner.options.reference_scope) |scope| {
        if (scope.capture(owner, target)) |local| {
            const bytes = try allocator.dupe(u8, local.attachment);
            self.* = .{ .owner = owner, .allocator = allocator, .capability = retains[0].ref, .recipe = .{ .recipe = .{ .local = .{ .attachment = bytes, .target = local.target } } }, .bytes = bytes, .state = .ready };
            return @ptrCast(self);
        } else |err| if (err != error.NotDurable) return err;
    }
    try validateForeignObject(owner.host, target);
    const supplied = uri orelse return error.NotDurable;
    if (supplied.len > max_uri_bytes) return error.RecordTooLarge;
    const sturdy = try model.uri.parseSturdyref(scratch, supplied);
    const length = try model.uri.measureSturdyrefForProfile(.v1_0, sturdy);
    if (length > max_uri_bytes) return error.RecordTooLarge;
    const bytes = try allocator.alloc(u8, length);
    errdefer allocator.free(bytes);
    const written = try model.uri.writeSturdyrefForProfileBounded(.v1_0, sturdy, bytes);
    std.debug.assert(written.complete and written.len == length);
    const enliven = if (work) |lease| try lease.enliven(owner.host, allocator, sturdy) else try owner.host.enlivenCapability(allocator, sturdy);
    self.* = .{ .owner = owner, .allocator = allocator, .capability = retains[0].ref, .recipe = .{ .recipe = .{ .foreign = bytes } }, .bytes = bytes, .enliven = enliven, .state = .pending };
    _ = self.result();
    return @ptrCast(self);
}

/// The same Host object-target gate owns admission on save and cold restore.
/// A URI cannot give a pending promise a supported field representation.
pub fn validateForeignObject(host: *driver.Host, capability: driver.Capability) !void {
    const home = host.capabilitySession(capability) orelse return error.NotDurable;
    _ = host.routeCapability(home, capability, true) catch |err| switch (err) {
        error.UncallableTarget => return error.NotDurable,
        else => return err,
    };
}
