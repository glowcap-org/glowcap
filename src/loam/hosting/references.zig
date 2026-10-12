//! Call-owned preparation of declared durable fields and held replacements.
//! Disk reads use the attachment's lane. Network work stays in Host.
const std = @import("std");
const model = @import("model");
const core = @import("loam_core");
const driver = @import("driver_core");
const h = @import("attachment.zig");
const preparation = @import("preparation.zig");
const recipe_mod = @import("reference_recipe.zig");
const save_mod = @import("reference_save.zig");
const live_mod = @import("live_scope.zig");
pub const schema = recipe_mod.schema;
pub const Scope = @import("reference_scope.zig").Scope;
pub const Save = save_mod.Save;
pub const beginSave = save_mod.begin;
/// The longest supplied or canonical URI a recipe stores.
pub const max_uri_bytes = save_mod.max_uri_bytes;

pub const AllocationBound = @import("call_memory.zig").AllocationBound;

/// Preparation, one proof and recipe payload per save, plus one transient URI
/// window. Caller-owned declarations, snapshots, callback storage and reply
/// marshaling are separate demand. Host network state uses its own budgets.
/// uri_bytes bounds supplied or stored inputs. Save canonicalization may expand.
pub fn allocationBound(restores: usize, saves: usize, uri_bytes: usize) !AllocationBound {
    if (uri_bytes > max_uri_bytes) return error.RecordTooLarge;
    const requests = try std.math.add(usize, restores, saves);
    var bound: AllocationBound = .{};
    try bound.include(@sizeOf(Set), @alignOf(Set), 1);
    if (requests == 0) return bound;
    try bound.include(try std.math.mul(usize, requests, @sizeOf(Set.Slot)), @alignOf(Set.Slot), 1);
    try bound.include(try std.math.mul(usize, requests, @sizeOf(usize)), @alignOf(usize), 2);
    // A dependent live save adds one canonical target spine before the facet
    // retains that target. Its reservation then uses the ordinary save spine.
    try bound.include(@sizeOf(driver.Host.StagedCapabilityRetain), @alignOf(driver.Host.StagedCapabilityRetain), try std.math.mul(usize, saves, 2));
    try bound.merge(try save_mod.allocationBound(saves, uri_bytes));
    try bound.include(@sizeOf(SavedState), @alignOf(SavedState), saves);
    try bound.include(try std.math.add(usize, @max(try Save.canonicalUriBytesBound(uri_bytes), Scope.max_name_bytes), 1), 1, saves);
    try bound.include(@sizeOf(driver.Host.Enliven), @alignOf(driver.Host.Enliven), restores);
    const parse = try model.uri.parseAllocationBound(uri_bytes, model.max_locator_hint_count);
    try bound.merge(.{ .bytes = parse.bytes, .allocations = parse.allocations });
    // Save admission owns this temporary spine in the same parse window.
    if (saves != 0) try bound.include(@sizeOf(driver.Host.StagedCapabilityRetain), @alignOf(driver.Host.StagedCapabilityRetain), 1);
    return bound;
}

pub const Request = union(enum) {
    restore: usize,
    /// A field in the preparation's registered view inventory. Zero names the
    /// original root. Additional views must come from that preparation, never
    /// a caller-selected object ID. Exact revision checks survive restoration.
    restore_record: struct { record: usize, index: usize, retain_uri: bool = false, metadata_only: bool = false },
    /// The durable URI was obtained before this transaction. Host verifies it
    /// names this exact held capability. Omitting it supports local capture.
    save: struct { capability: driver.Capability, uri: ?[]const u8 = null },
    /// Explicit Host-lifetime custody. Restart never restores this authority.
    save_live: driver.Capability,
    /// Prepare one stable facet governed by both actual held capabilities.
    save_live_dependent: struct { source: driver.Capability, target: driver.Capability },
};

/// Extra demand for explicitly requested URI retention. Ordinary restorations
/// keep their single transient recipe window and allocate no retained URI.
pub fn retainedUriAllocationBound(count: usize, uri_bytes: usize) !AllocationBound {
    if (uri_bytes > max_uri_bytes) return error.RecordTooLarge;
    var bound: AllocationBound = .{};
    try bound.include(uri_bytes, 1, count);
    return bound;
}
pub const Replacement = union(enum) { edge: core.Edge, saved: *Saved };

/// A call-bound recipe proof. Application code cannot manufacture a saved
/// target from a name. Copies retain the actual capability through outcome.
pub const Saved = opaque {
    pub fn stage(self: *Saved, store: *core.Store) !core.Edge {
        const state: *SavedState = @ptrCast(@alignCast(self));
        if (store != state.call.attachment.store) return error.ForeignStore;
        if (store.phase != .staging) return error.WrongPhase;
        if (state.live) |live| return live.stage(store, state.call.arena());
        if (state.staged) |staged| if (std.meta.eql(staged.ticket, store.ticket.?)) return staged.edge;
        const edge = try state.recipe.stage(store, state.call.arena());
        state.staged = .{ .ticket = store.ticket.?, .edge = edge };
        return edge;
    }
};
const SavedState = struct {
    call: *h.Call,
    recipe: recipe_mod.Recipe,
    live: ?*live_mod.Reservation = null,
    /// One immutable recipe row serves every occurrence of this proof in the
    /// transaction. An aborted ticket never lends its consumed ID to a retry.
    staged: ?struct { ticket: core.Ticket, edge: core.Edge } = null,
};

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
            const state = try call.arena().create(SavedState);
            state.* = .{ .call = call, .recipe = switch (recipe) {
                .local => |local| .{ .local = .{ .attachment = try call.arena().dupe(u8, local.attachment), .target = local.target } },
                .foreign => |uri| .{ .foreign = try call.arena().dupe(u8, uri) },
                .live => return error.LiveReferenceRequiresDeclaration,
            } };
            break :blk .{ .saved = @ptrCast(state) };
        },
    };
}

pub fn hold(call: *h.Call, capability: driver.Capability) !driver.Capability {
    try call.held.ensureUnusedCapacity(call.arena(), 1);
    const retains = try call.attachment.host.retainValueCapabilities(call.arena(), &.{.{ .capability = capability }});
    call.adoptRetain(retains[0].ref);
    return retains[0].ref;
}

pub fn edgeAt(view: core.RecordView, index: usize) !core.Edge {
    const edge = try view.edgeAt(index);
    if (edge.strength != .strong) return error.NotDurable;
    return edge;
}

pub const Set = struct {
    call: *h.Call,
    views: union(enum) { one: core.RecordView, many: []const core.RecordView },
    slots: []Slot,
    // Slot permutations borrow views and capabilities; they retain no authority.
    // Restore keys are immutable. Capture keys become current after advance.
    restores: []usize,
    captures: []usize,
    captures_current: bool = false,
    index: usize = 0,
    pending: ?core.Ticket = null,
    live_checked_revision: ?u64 = null,
    const Slot = struct {
        request: Request,
        retention: ?core.Retention = null,
        lease: ?core.Lease = null,
        enliven: ?*driver.Host.Enliven = null,
        capability: ?driver.Capability = null,
        save: ?*Save = null,
        proof: ?*Saved = null,
        live: ?*live_mod.Reservation = null,
        live_epoch: ?@import("live_epoch.zig").Epoch = null,
        ready: bool = false,
        recipe: union(enum) { absent, local, foreign: []const u8, live } = .absent,
    };

    /// Each save declaration owns one Host retain before any request can wait.
    /// Slots and temporary retain spines use the bounded call arena. Starting
    /// a Save transfers custody by retiring this retain after Save owns its own.
    /// Error, reset and cancellation release unstarted declarations here.
    pub fn create(call: *h.Call, view: core.RecordView, requests: []const Request) !*Set {
        return createInventory(call, .{ .one = view }, requests);
    }

    /// Inventory borrows prepared snapshots through settlement. Slots and
    /// request custody share the existing retained arena and lifecycle.
    pub fn createViews(call: *h.Call, views: []const core.RecordView, requests: []const Request) !*Set {
        if (views.len == 0) return error.InvalidArgument;
        return createInventory(call, .{ .many = views }, requests);
    }

    fn createInventory(call: *h.Call, views: @FieldType(Set, "views"), requests: []const Request) !*Set {
        if (call.work) |work| try work.checkHost(call.attachment.host);
        if (call.references != null) return error.AlreadyPreparingReferences;
        const count = switch (views) {
            .one => 1,
            .many => |items| items.len,
        };
        for (requests) |request| if (request == .restore_record) {
            if (request.restore_record.record >= count) return error.ReferenceUnprepared;
            if (request.restore_record.metadata_only and !request.restore_record.retain_uri) return error.InvalidArgument;
        };
        const self = try call.arena().create(Set);
        const slots = try call.arena().alloc(Slot, requests.len);
        for (slots, requests) |*slot, request| slot.* = .{ .request = request };
        const restores = try call.arena().alloc(usize, requests.len);
        const captures = try call.arena().alloc(usize, requests.len);
        self.* = .{ .call = call, .views = views, .slots = slots, .restores = restores, .captures = captures };
        errdefer self.deinit();
        var count_restores: usize = 0;
        for (slots, 0..) |slot, i| {
            captures[i] = i;
            if (selectionOf(slot.request) != null) {
                restores[count_restores] = i;
                count_restores += 1;
            }
        }
        self.restores = restores[0..count_restores];
        std.mem.sort(usize, self.restores, self, restoreLess);
        for (slots) |*slot| switch (slot.request) {
            .save => |request| {
                const retained = try call.attachment.host.retainValueCapabilities(call.arena(), &.{.{ .capability = request.capability }});
                slot.capability = retained[0].ref;
            },
            .save_live => |capability| {
                const scope = call.attachment.options.live_scope orelse return error.LiveScopeRequired;
                slot.live = try scope.reserve(call.arena(), capability);
            },
            .save_live_dependent => |pair| {
                const scope = call.attachment.options.live_scope orelse return error.LiveScopeRequired;
                slot.live = try scope.reserveDependent(call.arena(), pair.source, pair.target);
            },
            else => {},
        };
        call.references = self;
        return self;
    }

    pub fn advance(self: *Set) !preparation.Preparation.Step {
        if (self.pending != null) return .waiting;
        if (self.index != self.slots.len) self.captures_current = false;
        const store = self.call.attachment.store;
        while (self.index < self.slots.len) {
            const slot = &self.slots[self.index];
            switch (slot.request) {
                .save_live, .save_live_dependent => switch (try self.prepareLive()) {
                    .ready => {},
                    else => |step| return step,
                },
                .save => |request| {
                    if (slot.save == null) {
                        // An inline handoff owns its eventual object before its
                        // exporter route exists. Retain that exact occurrence
                        // and resume this preparation after Host redemption.
                        _ = self.call.attachment.host.settledCapability(slot.capability.?) catch |err| switch (err) {
                            error.PromisePending => return .waiting,
                            else => return err,
                        };
                        var scratch = self.call.memory.scratch();
                        defer scratch.deinit();
                        slot.save = try save_mod.beginPrepared(self.call.attachment, self.call.arena(), scratch.allocator(), slot.capability.?, request.uri, self.call.work);
                        self.call.attachment.host.releaseCapabilityTerminal(slot.capability.?, null);
                        slot.capability = null;
                    }
                    switch (slot.save.?.result()) {
                        .pending => return .waiting,
                        .failed => |err| return err,
                        .ready => {},
                    }
                },
                .restore, .restore_record => {
                    const selection = selectionOf(slot.request).?;
                    const edge = try edgeAt(self.selected(selection.record), selection.index);
                    if (edge.restoration == .object) {
                        if (slot.request == .restore_record and slot.request.restore_record.retain_uri) slot.recipe = .local;
                        slot.ready = true;
                        self.index += 1;
                        continue;
                    }
                    // Retention precedes cold loading and network restoration.
                    if (slot.retention == null) slot.retention = try store.retain(edge.target);
                    if (slot.live_epoch) |epoch| {
                        switch (try self.prepareLive()) {
                            .ready => {},
                            else => |step| return step,
                        }
                        slot.capability = try self.call.attachment.options.live_scope.?.restore(self.call.arena(), edge.target, epoch);
                        if (slot.request == .restore_record and slot.request.restore_record.retain_uri) slot.recipe = .live;
                        slot.ready = true;
                        self.index += 1;
                        continue;
                    }
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
                    if (slot.request == .restore_record and slot.request.restore_record.metadata_only) {
                        // Inspection retains the canonical recipe in the same
                        // bounded Call allowance as URI-bearing restoration.
                        // It grants no capability and never dials or revives
                        // a local or expired live endpoint. Retire each row
                        // window before inspecting the next selected field.
                        slot.recipe = switch (recipe) {
                            .local => .local,
                            .foreign => |uri| .{ .foreign = try self.call.arena().dupe(u8, uri) },
                            .live => .live,
                        };
                        try store.release(slot.lease.?);
                        slot.lease = null;
                        slot.ready = true;
                        self.index += 1;
                        continue;
                    }
                    switch (recipe) {
                        .local => |local| {
                            const scope = self.call.attachment.options.reference_scope orelse return error.ReferenceScopeRequired;
                            const target = scope.find(local.attachment) orelse return .waiting;
                            slot.capability = try h.restoreEdge(target, local.target);
                        },
                        .foreign => |uri| {
                            if (slot.enliven == null) {
                                var scratch = self.call.memory.scratch();
                                defer scratch.deinit();
                                const sturdy = try model.uri.parseSturdyref(scratch.allocator(), uri);
                                slot.enliven = if (self.call.work) |work|
                                    try work.enliven(self.call.attachment.host, self.call.arena(), sturdy)
                                else
                                    try self.call.attachment.host.enlivenCapability(self.call.arena(), sturdy);
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
                        .live => |epoch| {
                            // The scalar marker survives this read window. A
                            // tiny cache can load it after retiring the recipe.
                            slot.live_epoch = epoch;
                            try store.release(slot.lease.?);
                            slot.lease = null;
                            switch (try self.prepareLive()) {
                                .ready => {},
                                else => |step| return step,
                            }
                            slot.capability = try self.call.attachment.options.live_scope.?.restore(self.call.arena(), edge.target, epoch);
                        },
                    }
                    if (slot.request == .restore_record and slot.request.restore_record.retain_uri) {
                        // Only explicit recipe consumers pay for this copy.
                        // The row lease retires before the next restoration;
                        // requested URI bytes belong to this Call through its
                        // callback and cannot pin an unbounded recipe window.
                        slot.recipe = switch (recipe) {
                            .local => .local,
                            .foreign => |uri| .{ .foreign = try self.call.arena().dupe(u8, uri) },
                            .live => .live,
                        };
                    }
                    // Exact restoration has completed. Its capability and the
                    // recipe retention own custody through settlement; the
                    // decoded row lends no bytes to a later slot. Releasing
                    // here bounds recipe residency to one active read window,
                    // even when fields span a large application graph.
                    if (slot.lease) |lease| try store.release(lease);
                    slot.lease = null;
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
        const lower = self.firstRestore(view, index);
        // Duplicate declarations preserve the original first-ready selection.
        for (self.restores[lower..]) |i| {
            if (self.restoreOrder(i, view, index) != .eq) break;
            const slot = self.slots[i];
            if (slot.ready and !(slot.request == .restore_record and slot.request.restore_record.metadata_only))
                return slot.capability orelse error.ReferenceUnprepared;
        }
        return error.ReferenceUnprepared;
    }

    /// Borrow the canonical URI after declared exact restoration or inspection. Local
    /// recipes return null. Live custody has no durable publication recipe.
    /// This uses the existing sorted selection spine, with no field scan.
    pub fn restoredUri(self: *Set, view: core.RecordView, index: usize) !?[]const u8 {
        const lower = self.firstRestore(view, index);
        for (self.restores[lower..]) |i| {
            if (self.restoreOrder(i, view, index) != .eq) break;
            const slot = self.slots[i];
            if (!slot.ready) continue;
            switch (slot.recipe) {
                .absent => continue,
                .local, .live => return null,
                .foreign => |uri| return uri,
            }
        }
        return error.ReferenceUnprepared;
    }

    fn firstRestore(self: *Set, view: core.RecordView, index: usize) usize {
        var lower: usize = 0;
        var upper = self.restores.len;
        while (lower < upper) {
            const middle = lower + (upper - lower) / 2;
            if (self.restoreOrder(self.restores[middle], view, index) == .lt) lower = middle + 1 else upper = middle;
        }
        return lower;
    }

    fn restoreOrder(self: *Set, i: usize, view: core.RecordView, field: usize) std.math.Order {
        const selection = selectionOf(self.slots[i].request).?;
        const prepared = self.selected(selection.record);
        inline for (.{ std.math.order(@backingInt(prepared.id.store), @backingInt(view.id.store)), std.math.order(prepared.id.incarnation, view.id.incarnation), std.math.order(prepared.id.sequence, view.id.sequence), std.math.order(prepared.revision, view.revision), std.math.order(selection.index, field) }) |order| {
            if (order != .eq) return order;
        }
        return .eq;
    }

    fn restoreLess(self: *Set, left: usize, right: usize) bool {
        const selection = selectionOf(self.slots[right].request).?;
        return switch (self.restoreOrder(left, self.selected(selection.record), selection.index)) {
            .lt => true,
            .gt => false,
            .eq => left < right,
        };
    }

    fn captureCapability(slot: Slot) ?driver.Capability {
        if (!slot.ready) return null;
        if (slot.live) |live| return live.capability;
        if (slot.capability) |held| return held;
        if (slot.save) |save| return save_mod.state(save).capability;
        return null;
    }

    fn capabilityOrder(left: driver.Capability, right: driver.Capability) std.math.Order {
        const registry = std.math.order(@intFromPtr(left.registry), @intFromPtr(right.registry));
        return if (registry == .eq) std.math.order(left.raw(), right.raw()) else registry;
    }

    fn captureLess(self: *Set, left: usize, right: usize) bool {
        const a = captureCapability(self.slots[left]) orelse return false;
        const b = captureCapability(self.slots[right]) orelse return true;
        return switch (capabilityOrder(a, b)) {
            .lt => true,
            .gt => false,
            .eq => if ((self.slots[left].live != null) != (self.slots[right].live != null)) self.slots[left].live != null else left < right,
        };
    }

    /// Borrow only a facet produced by this call's explicit declaration. The
    /// call owns its reservation. Obtaining it grants no reply disclosure.
    pub fn preparedDependent(self: *Set, source: driver.Capability, target: driver.Capability) !driver.Capability {
        for (self.slots) |slot| {
            if (!slot.ready or slot.request != .save_live_dependent) continue;
            const pair = slot.request.save_live_dependent;
            if (pair.source.eql(source) and pair.target.eql(target)) return slot.live.?.capability;
        }
        return error.ReferenceUnprepared;
    }

    /// Restored authority reuses a matching committed recipe edge, retained
    /// here through settlement. A prepared Save likewise owns its bytes and
    /// capability for that lifetime: create one borrowed proof, rather than
    /// duplicating a URI and retain for every field occurrence. Independently
    /// owned Saves still use copySaved because they may retire before the call.
    pub fn captured(self: *Set, capability: driver.Capability) !Replacement {
        if (!self.captures_current) {
            std.mem.sort(usize, self.captures, self, captureLess);
            self.captures_current = true;
        }
        var lower: usize = 0;
        var upper = self.captures.len;
        while (lower < upper) {
            const middle = lower + (upper - lower) / 2;
            const current = captureCapability(self.slots[self.captures[middle]]);
            if (current != null and capabilityOrder(current.?, capability) == .lt) lower = middle + 1 else upper = middle;
        }
        if (lower == self.captures.len) return error.ReferenceUnprepared;
        const slot = &self.slots[self.captures[lower]];
        const current = captureCapability(slot.*) orelse return error.ReferenceUnprepared;
        if (!current.eql(capability)) return error.ReferenceUnprepared;
        if (slot.live) |live| {
            if (slot.proof) |proof| return .{ .saved = proof };
            const state = try self.call.arena().create(SavedState);
            state.* = .{ .call = self.call, .recipe = .{ .live = live.scope.epoch.? }, .live = live };
            slot.proof = @ptrCast(state);
            return .{ .saved = slot.proof.? };
        }
        // Explicit live lifetime wins even when another declared restoration
        // or durable save names the same capability.
        if (selectionOf(slot.request)) |selection| {
            if (slot.capability) |held| if (held.eql(capability)) return .{ .edge = try edgeAt(self.selected(selection.record), selection.index) };
        }
        if (slot.save) |save| {
            const saved = save_mod.state(save);
            std.debug.assert(saved.capability.eql(capability));
            return switch (saved.recipe) {
                .edge => |edge| .{ .edge = edge },
                .recipe => |recipe| blk: {
                    if (slot.proof) |proof| break :blk .{ .saved = proof };
                    const state = try self.call.arena().create(SavedState);
                    state.* = .{ .call = self.call, .recipe = recipe };
                    slot.proof = @ptrCast(state);
                    break :blk .{ .saved = slot.proof.? };
                },
            };
        }
        return error.ReferenceUnprepared;
    }

    pub fn deinit(self: *Set) void {
        std.debug.assert(self.pending == null);
        const store = self.call.attachment.store;
        for (self.slots) |slot| {
            if (slot.live) |live| live.cancel();
            if (slot.save) |save| save.deinit();
            if (slot.enliven) |enliven| enliven.deinit();
            if (slot.capability) |capability| self.call.attachment.host.releaseCapabilityTerminal(capability, null);
            if (slot.lease) |lease| store.release(lease) catch unreachable;
            if (slot.retention) |retention| store.releaseRetention(retention) catch unreachable;
        }
    }

    /// The write owner confirms live custody even when later reply delivery
    /// refuses. Continuation confirmation keeps its independent Call slot.
    pub fn finish(self: *Set, ticket: core.Ticket, committed: bool) void {
        for (self.slots) |*slot| if (slot.live) |live| {
            live.finish(ticket, committed);
            if (live.phase == .committed) slot.live = null;
        };
        self.captures_current = false;
    }

    fn prepareLive(self: *Set) !preparation.Preparation.Step {
        const scope = self.call.attachment.options.live_scope orelse return error.LiveReferenceExpired;
        const epoch = scope.epoch orelse return error.LiveReferenceExpired;
        const store = self.call.attachment.store;
        if (self.live_checked_revision == store.metadata.revision) return .ready;
        const acquired = store.acquire(epoch.object) catch |err| {
            if (err == error.PendingRead) return .waiting;
            return err;
        };
        switch (acquired) {
            .read => |read| {
                self.pending = read.ticket;
                return .{ .read = read };
            },
            .ready => |lease| {
                defer store.release(lease) catch unreachable;
                try epoch.check(store, lease);
                self.live_checked_revision = store.metadata.revision;
                return .ready;
            },
        }
    }

    fn selected(self: *Set, index: usize) core.RecordView {
        return switch (self.views) {
            .one => |view| view,
            .many => |views| views[index],
        };
    }
};

fn selectionOf(request: Request) ?struct { record: usize, index: usize } {
    return switch (request) {
        .restore => |index| .{ .record = 0, .index = index },
        .restore_record => |selection| .{ .record = selection.record, .index = selection.index },
        .save, .save_live, .save_live_dependent => null,
    };
}
