//! Call-owned preparation of declared durable fields and held replacements.
//! Disk reads use the attachment's lane; network work stays in Host.
const std = @import("std");
const model = @import("model");
const core = @import("loam_core");
const driver = @import("driver_core");
const h = @import("attachment.zig");
const preparation = @import("preparation.zig");
const recipe_mod = @import("reference_recipe.zig");
const save_mod = @import("reference_save.zig");
pub const schema = recipe_mod.schema;
pub const Scope = @import("reference_scope.zig").Scope;
pub const Save = save_mod.Save;
pub const beginSave = save_mod.begin;

pub const Request = union(enum) {
    restore: usize,
    /// The durable URI was obtained before this transaction. Host verifies it
    /// names this exact held capability; omitting it supports local capture.
    save: struct { capability: driver.Capability, uri: ?[]const u8 = null },
};
pub const Replacement = union(enum) { edge: core.Edge, saved: *Saved };

/// A call-bound recipe proof. Application code cannot manufacture a saved
/// target from a name; copies retain the actual capability through outcome.
pub const Saved = opaque {
    pub fn stage(self: *Saved, store: *core.Store) !core.Edge {
        const state: *SavedState = @ptrCast(@alignCast(self));
        if (store != state.call.attachment.store) return error.ForeignStore;
        return state.recipe.stage(store, state.call.arena);
    }
};
const SavedState = struct { call: *h.Call, recipe: recipe_mod.Recipe };

pub fn copySaved(call: *h.Call, save: *Save) !Replacement {
    const saved = save_mod.state(save);
    if (saved.owner.host != call.attachment.host or saved.owner.store != call.attachment.store) return error.ForeignStore;
    if (saved.owner != call.attachment) return error.ForeignAttachment;
    switch (save.result()) {
        .pending => return error.ReferencePending,
        .failed => |err| return err,
        .ready => {},
    }
    _ = try hold(call, saved.capability);
    return switch (saved.recipe) {
        .edge => |edge| .{ .edge = edge },
        .recipe => |recipe| blk: {
            const state = try call.arena.create(SavedState);
            state.* = .{ .call = call, .recipe = switch (recipe) {
                .local => |local| .{ .local = .{ .attachment = try call.arena.dupe(u8, local.attachment), .target = local.target } },
                .foreign => |uri| .{ .foreign = try call.arena.dupe(u8, uri) },
            } };
            break :blk .{ .saved = @ptrCast(state) };
        },
    };
}

pub fn hold(call: *h.Call, capability: driver.Capability) !driver.Capability {
    try call.held.ensureUnusedCapacity(call.arena, 1);
    const retains = try call.attachment.host.retainValueCapabilities(call.arena, &.{.{ .capability = capability }});
    call.adoptRetain(retains[0].ref);
    return retains[0].ref;
}

pub fn edgeAt(view: core.RecordView, index: usize) !core.Edge {
    if (index >= view.edge_count) return error.NoSuchEdge;
    var iterator = view.edges();
    var current: usize = 0;
    while (iterator.next()) |edge| : (current += 1) if (current == index) {
        if (edge.strength != .strong) return error.NotDurable;
        return edge;
    };
    unreachable;
}

pub const Set = struct {
    call: *h.Call,
    view: core.RecordView,
    slots: []Slot,
    index: usize = 0,
    pending: ?core.Ticket = null,
    const Slot = struct {
        request: Request,
        retention: ?core.Retention = null,
        lease: ?core.Lease = null,
        enliven: ?*driver.Host.Enliven = null,
        capability: ?driver.Capability = null,
        save: ?*Save = null,
        ready: bool = false,
    };

    /// Each save declaration owns one Host retain before any request can wait.
    /// Slots and temporary retain spines use the bounded call arena. Starting
    /// a Save transfers custody by retiring this retain after Save owns its own;
    /// error, reset and cancellation release unstarted declarations here.
    pub fn create(call: *h.Call, view: core.RecordView, requests: []const Request) !*Set {
        if (call.references != null) return error.AlreadyPreparingReferences;
        const self = try call.arena.create(Set);
        const slots = try call.arena.alloc(Slot, requests.len);
        for (slots, requests) |*slot, request| slot.* = .{ .request = request };
        self.* = .{ .call = call, .view = view, .slots = slots };
        errdefer self.deinit();
        for (slots) |*slot| if (slot.request == .save) {
            const retained = try call.attachment.host.retainValueCapabilities(call.arena, &.{.{ .capability = slot.request.save.capability }});
            slot.capability = retained[0].ref;
        };
        call.references = self;
        return self;
    }

    pub fn advance(self: *Set) !preparation.Preparation.Step {
        if (self.pending != null) return .waiting;
        const store = self.call.attachment.store;
        while (self.index < self.slots.len) {
            const slot = &self.slots[self.index];
            switch (slot.request) {
                .save => |request| {
                    if (slot.save == null) {
                        slot.save = try save_mod.beginPrepared(self.call.attachment, self.call.arena, slot.capability.?, request.uri);
                        self.call.attachment.host.releaseCapabilityTerminal(slot.capability.?, null);
                        slot.capability = null;
                    }
                    switch (slot.save.?.result()) {
                        .pending => return .waiting,
                        .failed => |err| return err,
                        .ready => {},
                    }
                },
                .restore => |index| {
                    const edge = try edgeAt(self.view, index);
                    if (edge.restoration == .object) {
                        slot.ready = true;
                        self.index += 1;
                        continue;
                    }
                    // Retention precedes cold loading and network restoration.
                    if (slot.retention == null) slot.retention = try store.retain(edge.target);
                    if (slot.lease == null) {
                        const acquired = store.acquire(edge.target) catch |err| {
                            if (err == error.PendingRead) return .waiting;
                            return err;
                        };
                        switch (acquired) {
                            .ready => |lease| slot.lease = lease,
                            .read => |read| {
                                self.pending = read.ticket;
                                return .{ .read = read };
                            },
                        }
                    }
                    const recipe = try recipe_mod.Recipe.decode(try store.currentView(slot.lease.?));
                    switch (recipe) {
                        .local => |local| {
                            const scope = self.call.attachment.options.reference_scope orelse return error.ReferenceScopeRequired;
                            const target = scope.find(local.attachment) orelse return .waiting;
                            slot.capability = try h.restoreEdge(target, local.target);
                        },
                        .foreign => |uri| {
                            if (slot.enliven == null) {
                                const sturdy = try model.uri.parseSturdyref(self.call.arena, uri);
                                slot.enliven = try self.call.attachment.host.enlivenCapability(self.call.arena, sturdy);
                            }
                            switch (slot.enliven.?.result()) {
                                .pending => return .waiting,
                                .failed => return error.RestorationFailed,
                                .ready => |ready| {
                                    try save_mod.validateForeignObject(self.call.attachment.host, ready.capability);
                                    slot.capability = try slot.enliven.?.take();
                                },
                            }
                        },
                    }
                },
            }
            slot.ready = true;
            self.index += 1;
        }
        return .ready;
    }

    pub fn completeRead(self: *Set, ticket: core.Ticket, result: core.ReadResult) !void {
        if (self.pending == null or !std.meta.eql(self.pending.?, ticket)) return error.StaleCompletion;
        self.pending = null;
        try self.call.attachment.store.completeRead(ticket, result);
    }

    pub fn restored(self: *Set, view: core.RecordView, index: usize) !driver.Capability {
        if (!view.id.eql(self.view.id) or view.revision != self.view.revision) return error.ReferenceUnprepared;
        for (self.slots) |slot| if (slot.request == .restore and slot.request.restore == index and slot.ready) {
            return slot.capability orelse return error.ReferenceUnprepared;
        };
        return error.ReferenceUnprepared;
    }

    pub fn captured(self: *Set, capability: driver.Capability) !Replacement {
        for (self.slots) |slot| if (slot.save) |save| {
            if (slot.ready and save_mod.state(save).capability.eql(capability)) return copySaved(self.call, save);
        };
        return error.ReferenceUnprepared;
    }

    pub fn deinit(self: *Set) void {
        std.debug.assert(self.pending == null);
        const store = self.call.attachment.store;
        for (self.slots) |slot| {
            if (slot.save) |save| save.deinit();
            if (slot.enliven) |enliven| enliven.deinit();
            if (slot.capability) |capability| self.call.attachment.host.releaseCapabilityTerminal(capability, null);
            if (slot.lease) |lease| store.release(lease) catch unreachable;
            if (slot.retention) |retention| store.releaseRetention(retention) catch unreachable;
        }
    }
};
