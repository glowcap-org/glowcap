//! Owned locator and sturdyref handle storage.
//!
//! URI parsing, public construction, typed hints, and borrowed accessors all
//! project this one ownership graph. A locator refresh is the mutation commit:
//! its C view changes only after every new hint projection succeeds.

const std = @import("std");

const model = @import("model");
const c = @import("../mod.zig");
const shared = @import("c_abi_shared");
const locator_adapter = shared.locator_adapter;

pub const LocatorPayload = struct {
    allocator: std.mem.Allocator,
    transport: []u8,
    designator: []u8,
    hints: std.ArrayListUnmanaged(model.HintEntry),
    hint_views: std.ArrayListUnmanaged(shared.GlowcapLocatorHintView),
    wire_form: model.Hints.WireForm,
    view: shared.GlowcapLocatorView,

    pub fn peer(self: *const LocatorPayload) model.PeerLocator {
        return .{
            .transport = self.transport,
            .designator = self.designator,
            .hints = .{ .entries = self.hints.items, .wire_form = self.wire_form },
        };
    }

    pub fn refreshView(self: *LocatorPayload) !void {
        self.hint_views.clearRetainingCapacity();
        try self.hint_views.resize(self.allocator, self.hints.items.len);
        self.view = try locator_adapter.project(self.peer(), self.hint_views.items);
    }

    pub fn deinit(self: *LocatorPayload) void {
        for (self.hints.items) |entry| model.freeHintEntry(self.allocator, entry);
        self.hints.deinit(self.allocator);
        self.hint_views.deinit(self.allocator);
        self.allocator.free(self.transport);
        self.allocator.free(self.designator);
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

pub const SturdyRefPayload = struct {
    allocator: std.mem.Allocator,
    locator: *LocatorPayload,
    swissnum: []u8,

    pub fn deinit(self: *SturdyRefPayload) void {
        self.locator.deinit();
        self.allocator.free(self.swissnum);
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

pub fn locFromOpaque(loc: ?*c.GlowcapLocator) ?*LocatorPayload {
    return @ptrCast(@alignCast(loc orelse return null));
}

pub fn sturdyFromOpaque(sturdyref: ?*c.GlowcapSturdyRef) ?*SturdyRefPayload {
    return @ptrCast(@alignCast(sturdyref orelse return null));
}

pub fn adoptPeer(allocator: std.mem.Allocator, peer: model.PeerLocator) !*LocatorPayload {
    model.validatePeerLocator(peer) catch {
        model.freePeerLocator(allocator, peer);
        return error.InvalidArgument;
    };
    const payload = allocator.create(LocatorPayload) catch |err| {
        model.freePeerLocator(allocator, peer);
        return err;
    };
    payload.* = .{
        .allocator = allocator,
        .transport = @constCast(peer.transport),
        .designator = @constCast(peer.designator),
        .hints = .fromOwnedSlice(@constCast(peer.hints.entries)),
        .hint_views = .empty,
        .wire_form = peer.hints.wire_form,
        .view = undefined,
    };
    payload.refreshView() catch |err| {
        payload.deinit();
        return err;
    };
    return payload;
}

pub fn adoptSturdyRef(allocator: std.mem.Allocator, sturdyref: model.SturdyRef) !*SturdyRefPayload {
    errdefer allocator.free(sturdyref.swissnum);
    const locator = try adoptPeer(allocator, sturdyref.peer);
    errdefer locator.deinit();
    const payload = try allocator.create(SturdyRefPayload);
    payload.* = .{
        .allocator = allocator,
        .locator = locator,
        .swissnum = @constCast(sturdyref.swissnum),
    };
    return payload;
}
