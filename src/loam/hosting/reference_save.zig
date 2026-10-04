//! Saving proves a recipe names the capability actually held by the caller.
//! Host owns all remote restoration; local capture requires no networking.
const std = @import("std");
const model = @import("model");
const core = @import("loam_core");
const driver = @import("driver_core");
const h = @import("attachment.zig");
const Recipe = @import("reference_recipe.zig").Recipe;

pub const Save = opaque {
    pub const Result = union(enum) { pending, ready, failed: anyerror };

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
            .ready => |ready| self.state = if (ready.capability.eql(self.capability)) .ready else .{ .failed = error.DurableReferenceMismatch },
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
    return beginPrepared(owner, allocator, capability, uri);
}

/// Internal preparation at a top-level Host boundary inside Attachment.advance.
pub fn beginPrepared(owner: *h.Attachment, allocator: std.mem.Allocator, capability: driver.Capability, uri: ?[]const u8) !*Save {
    try owner.host.refuseReentry();
    if (owner.closing) return error.AttachmentClosed;
    if (owner.reference_saves >= owner.options.max_reference_saves) return error.ReferenceCapacity;
    owner.reference_saves += 1;
    errdefer owner.reference_saves -= 1;
    const self = try allocator.create(State);
    errdefer allocator.destroy(self);
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const retains = try owner.host.retainValueCapabilities(scratch.allocator(), &.{.{ .capability = capability }});
    errdefer owner.host.releaseUntransferredCapabilityRetains(retains);
    if (owner.capture(capability)) |edge| {
        self.* = .{ .owner = owner, .allocator = allocator, .capability = retains[0].ref, .recipe = .{ .edge = edge }, .state = .ready };
        return @ptrCast(self);
    } else |err| if (err != error.NotDurable) return err;
    if (owner.options.reference_scope) |scope| {
        if (scope.capture(owner, capability)) |local| {
            const bytes = try allocator.dupe(u8, local.attachment);
            self.* = .{ .owner = owner, .allocator = allocator, .capability = retains[0].ref, .recipe = .{ .recipe = .{ .local = .{ .attachment = bytes, .target = local.target } } }, .bytes = bytes, .state = .ready };
            return @ptrCast(self);
        } else |err| if (err != error.NotDurable) return err;
    }
    try validateForeignObject(owner.host, capability);
    const supplied = uri orelse return error.NotDurable;
    if (supplied.len > 4096) return error.RecordTooLarge;
    const sturdy = try model.uri.parseSturdyref(scratch.allocator(), supplied);
    const bytes = try model.uri.writeSturdyref(allocator, sturdy);
    errdefer allocator.free(bytes);
    if (bytes.len > 4096) return error.RecordTooLarge;
    const enliven = try owner.host.enlivenCapability(allocator, sturdy);
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
