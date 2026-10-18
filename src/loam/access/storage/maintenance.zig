//! One prepared, revision-bound owner maintenance step in the ordinary Store.
const std = @import("std");
const core = @import("loam_access_core");
const loam = @import("loam_core");
const records = @import("loam_access_records");
const Read = @import("read.zig").Read;
const Step = @import("read.zig").Step;
const Load = @import("load.zig").Load;
const Query = @import("directory_query.zig").DirectoryQuery;
const Edit = @import("directory_edit.zig").DirectoryEdit;
const Probe = @import("retirement_probe.zig").Probe;
const Cancellation = @import("observation_cancellation.zig").Cancellation;
const record = @import("record.zig");
const Position = records.MaintenancePosition;
const grant_retirement = @import("grant_retirement.zig");
const history = @import("history.zig");

const State = struct {
    read: Read = undefined,
    command: Position.Command,
    sequence: u64,
    load: Load = .{},
    query: ?Query = null,
    edit: ?Edit = null,
    entry: ?Query.Entry = null,
    lease: ?loam.Lease = null,
    probe: ?Probe = null,
    cancellation: ?*Cancellation = null,
    terminal: ?records.TerminalRecord = null,
    grant_path: ?grant_retirement.Path = null,
    grant_child_edit: ?Edit = null,
    publication_ids: records.ObservationRecord.Publications = @splat(null),
    observation_index: ?records.ObservationIndexRecord = null,
    remove: bool = false,
    missing: bool = false,
    phase_done: bool = false,
    replay: bool = false,
    ready: bool = false,
    staged: bool = false,

    fn advance(self: *State) !Step {
        try self.read.current();
        if (self.staged) return error.WrongPhase;
        if (self.ready) return .ready;
        for (0..256) |_| {
            const read_step = try self.read.advance();
            if (read_step != .ready) return read_step;
            try loam.reload(self.prepare()) orelse continue;
            if (self.ready) return .ready;
            const step = try loam.reload((if (self.read.header.maintenance.phase == .observations) self.observation() else self.indexed())) orelse continue;
            if (step != .ready) return step;
            if (self.phase_done) self.ready = true;
            if (self.ready) return .ready;
        }
        return .waiting;
    }

    fn prepare(self: *State) !void {
        const header = self.read.header;
        const current = header.maintenance;
        if (self.sequence < current.sequence) {
            if (self.sequence != current.sequence - 1) return error.ExpiredSequence;
            if (self.command != current.last) return error.SequenceConflict;
            self.replay = true;
            self.ready = true;
            return;
        }
        if (self.sequence != current.sequence) return error.FutureSequence;
        if (current.sequence == std.math.maxInt(u64)) return error.SequenceExhausted;
        switch (self.command) {
            .none => return error.InvalidArguments,
            .sweep => {
                if (header.lifecycle != .active) return error.OwnerRetired;
                if (current.phase != .idle) return error.MaintenanceInProgress;
                self.ready = true;
            },
            .retire => {
                if (header.lifecycle != .active) return error.OwnerRetired;
                self.ready = true;
            },
            .step => if (current.phase == .idle) return error.NoMaintenance,
        }
    }

    fn acquire(self: *State, id: loam.ObjectId) !Step {
        if (self.lease != null) return .ready;
        const loaded = self.load.acquire(self.read.store, id) catch |err| {
            if (err == error.Gone and self.read.header.maintenance.phase == .identities) {
                self.load.failure = null;
                self.remove = true;
                self.missing = true;
                return .ready;
            }
            return err;
        };
        return switch (loaded) {
            .read => |request| .{ .read = request },
            .waiting => .waiting,
            .ready => |lease| result: {
                self.lease = lease;
                break :result .ready;
            },
        };
    }

    fn observation(self: *State) !Step {
        const root = self.read.header.observations orelse {
            self.phase_done = true;
            return .ready;
        };
        if (self.observation_index == null) {
            const row = switch (try self.load.resolve(self.read.store, root)) {
                .read => |request| return .{ .read = request },
                .waiting => return .waiting,
                .ready => |row| row,
            };
            defer row.release(self.read.store);
            self.observation_index = try records.ObservationIndexRecord.decode(row.view);
        }
        const index = self.observation_index.?;
        const cursor = self.read.header.maintenance.cursor;
        if (cursor >= index.count) {
            self.phase_done = true;
            return .ready;
        }
        const step = try self.acquire(index.contexts[@intCast(cursor)]);
        if (step != .ready) return step;
        const context = try records.ObservationRecord.decode(try self.read.store.currentView(self.lease.?));
        if (!context.owner.eql(self.read.owner_object)) return error.InvalidRecord;
        if (context.descriptor == null) return error.InvalidRecord;
        if (self.probe == null) self.probe = .{ .read = &self.read, .cursor = context.descriptor };
        const probed = try self.probe.?.advance();
        if (probed != .ready) return probed;
        self.remove = self.probe.?.terminal;
        if (self.remove) {
            if (self.cancellation == null) self.cancellation = try Cancellation.init(self.read.store, self.lease.?);
            const prepared = try self.cancellation.?.advance();
            if (prepared != .ready) return prepared;
            self.publication_ids = try self.cancellation.?.publications();
        }
        self.ready = true;
        return .ready;
    }

    fn indexed(self: *State) !Step {
        const position = self.read.header.maintenance;
        const family: records.DirectoryPage.Family = switch (position.phase) {
            .identities => .identity,
            .grants => .grant,
            .resources => .resource,
            else => return error.InvalidRecord,
        };
        const root = self.read.header.root(family);
        if (self.query == null) self.query = Query.initAt(&self.read, root, family, position.cursor);
        if (self.entry == null) {
            const step = try self.query.?.advance();
            if (step != .ready) return step;
            self.entry = self.query.?.entry;
            if (self.entry == null) {
                self.phase_done = self.query.?.done;
                return .ready;
            }
        }
        const entry = self.entry.?;
        const step = try self.acquire(entry.object);
        if (step != .ready) return step;
        if (!self.missing) {
            const classified = try self.classify(family);
            if (classified != .ready) return classified;
        }
        if (self.remove) {
            if (self.grant_path) |path| if (path.count > 1) {
                if (self.grant_child_edit == null) {
                    const row = try history.row(&self.read, .{ .grant = path.ids[1] });
                    var parent: records.GrantRecord = undefined;
                    try parent.decodeOwned(self.read.allocator, row.view.payload);
                    defer parent.deinit(self.read.allocator);
                    self.grant_child_edit = Edit.init(&self.read, .grant, parent.children, entry.slot);
                }
                const child_step = try self.grant_child_edit.?.advance();
                if (child_step != .ready) return child_step;
            };

            if (self.edit == null) self.edit = Edit.init(&self.read, family, root, entry.slot);
            const prepared = try self.edit.?.advance();
            if (prepared != .ready) return prepared;
        }
        self.ready = true;
        return .ready;
    }

    fn classify(self: *State, family: records.DirectoryPage.Family) !Step {
        const view = try self.read.store.currentView(self.lease.?);
        if (view.schema == records.profile.terminal) {
            const kind = (try records.TerminalRecord.decode(view)).kind;
            switch (family) {
                .identity => if (kind != .capability and kind != .endpoint) return error.InvalidRecord,
                .grant => if (kind != .grant) return error.InvalidRecord,
                .resource => if (kind != .resource) return error.InvalidRecord,
            }
            self.remove = true;
            return .ready;
        }
        if (family == .identity) {
            var descriptor = view.id;
            if (view.schema == records.profile.endpoint) {
                const endpoint = try records.EndpointRecord.decode(view);
                descriptor = endpoint.descriptor;
                self.terminal = .{ .kind = .endpoint, .derivation_floor = endpoint.derivations.next, .mutation_floor = endpoint.mutations.next };
                self.publication_ids[0] = endpoint.publication;
            } else if (view.schema == records.profile.capability) {
                self.terminal = .{ .kind = .capability };
            } else return error.InvalidRecord;
            if (self.probe == null) self.probe = .{ .read = &self.read, .cursor = descriptor };
            const step = try self.probe.?.advance();
            if (step != .ready) return step;
            self.remove = self.probe.?.terminal;
            if (!self.remove and self.terminal.?.kind == .endpoint) {
                const endpoint = try records.EndpointRecord.decode(view);
                if (endpoint.content) |content| {
                    var resources = try self.read.resourceView();
                    _ = resources.get(content.resource) catch |err| switch (err) {
                        error.Gone => {
                            self.remove = true;
                            if (self.publication_ids[0] == null) self.publication_ids[0] = endpoint.publication;
                            return .ready;
                        },
                        else => return err,
                    };
                }
            }
            if (!self.remove) self.publication_ids = @splat(null);
        } else if (family == .resource) {
            const value = try records.ResourceRecord.decode(view);
            if (value.resource.id.slot != self.entry.?.slot or value.resource.id.owner != self.read.header.owner) return error.InvalidRecord;
            self.remove = !value.live or self.read.header.lifecycle != .active;
            self.terminal = .{ .kind = .resource };
        } else {
            var value: records.GrantRecord = undefined;
            try value.decodeOwned(self.read.allocator, view.payload);
            defer value.deinit(self.read.allocator);
            if (value.grant.id.slot != self.entry.?.slot or value.grant.id.owner != self.read.header.owner) return error.InvalidRecord;
            self.remove = self.read.header.lifecycle != .active;
            if (!self.remove) {
                var grants = try self.read.grantView();
                const status = grants.effectiveStatus(value.grant.id) catch |err| switch (err) {
                    error.Gone => .revoked,
                    else => return err,
                };
                self.remove = status == .revoked;
                if (self.remove) self.grant_path = try grant_retirement.prepare(&self.read, value.grant.id, value.grant.parent);
            }
            self.terminal = .{ .kind = .grant };
        }
        return .ready;
    }
};

pub const Maintenance = opaque {
    pub const Command = Position.Command;
    pub const Result = struct { sequence: u64, phase: Position.Phase, retired: bool, replay: bool };
    pub const Retirement = Cancellation.Retirement;

    /// Trusted owner administration. No use/control handle can construct this
    /// operation. Capacity bounds model ancestry retained for terminal checks.
    pub fn init(allocator: std.mem.Allocator, store: *loam.Store, owner: loam.ObjectId, command: Command, sequence: u64, capacity: usize) !*Maintenance {
        const value = try allocator.create(State);
        errdefer allocator.destroy(value);
        value.* = .{ .command = command, .sequence = sequence };
        try value.read.init(allocator, store, owner, capacity, null);
        return @ptrCast(value);
    }
    pub fn advance(self: *Maintenance) !Step {
        return backing(self).advance();
    }
    pub fn publications(self: *Maintenance) !records.ObservationRecord.Publications {
        const value = backing(self);
        try value.read.current();
        if (!value.ready) return error.NotPrepared;
        return value.publication_ids;
    }
    pub fn result(self: *Maintenance) !Result {
        const value = backing(self);
        try value.read.current();
        if (!value.ready) return error.NotPrepared;
        const header = value.read.header;
        var phase = header.maintenance.phase;
        var retired = header.lifecycle == .retired;
        if (!value.replay and !value.staged) {
            if (value.command == .sweep or value.command == .retire) phase = .observations else if (value.phase_done) phase = phase.next();
            retired = phase == .idle and header.lifecycle == .retiring;
        }
        return .{ .sequence = header.maintenance.sequence + @as(u64, @intFromBool(!value.replay and !value.staged)), .phase = phase, .retired = retired, .replay = value.replay };
    }
    pub fn stage(self: *Maintenance, retirement: ?Retirement) !bool {
        const value = backing(self);
        try value.read.current();
        const store = value.read.store;
        if (!value.ready or value.staged or store.phase != .staging) return error.WrongPhase;
        if (value.replay) return false;
        try value.read.opened();
        if (value.read.header.maintenance.sequence != value.sequence) return error.RevisionConflict;
        if (value.lease) |lease| if (try store.proposed((try store.currentView(lease)).id) != null) return error.RevisionConflict;
        if (value.edit) |*edit| try edit.rebaseProposed(value.read.header.root(edit.family));
        for (value.publication_ids) |id| if (id != null and retirement == null) return error.RetirementRequired;
        errdefer if (store.phase == .staging) store.abort() catch unreachable;
        value.read.transaction = store.ticket;
        if (value.grant_path) |*path| try grant_retirement.stage(&value.read, path, if (value.grant_child_edit) |*edit| edit else null);
        if (value.cancellation) |cancellation| {
            _ = try cancellation.stage(retirement);
        } else if (value.remove and value.lease != null and value.terminal != null) {
            if (retirement) |transition| try transition.stage(transition.context, value.publication_ids);
            const view = try store.currentView(value.lease.?);
            try record.putEncoded(store, view.id, records.profile.terminal, value.terminal.?, &.{}, view.revision, .reachable);
        }
        var header = value.read.header;
        if (value.command == .retire) {
            header.lifecycle = .retiring;
            header.maintenance.phase = .observations;
            header.maintenance.cursor = 0;
        } else if (value.command == .sweep) {
            header.maintenance.phase = .observations;
            header.maintenance.cursor = 0;
        } else if (value.phase_done) {
            header.maintenance.cursor = 0;
            header.maintenance.phase = header.maintenance.phase.next();
            if (header.maintenance.phase == .idle and header.lifecycle == .retiring) {
                header.lifecycle = .retired;
                header.resources = null;
                header.grants = null;
                header.identities = null;
                header.observations = null;
                header.roots = null;
                header.history = null;
            }
        } else if (value.entry) |entry| {
            header.maintenance.cursor = @as(u64, entry.slot) + 1;
            if (value.remove) {
                header.setRoot(value.edit.?.family, try value.edit.?.stage(null));
            }
        } else if (!value.remove) header.maintenance.cursor += 1;
        header.maintenance.sequence += 1;
        header.maintenance.last = value.command;
        if (value.command == .retire) header.control_revision = std.math.add(u64, header.control_revision, 1) catch return error.RevisionExhausted;
        try record.putOwner(&value.read, &header);
        value.staged = true;
        return true;
    }
    pub fn completeRead(self: *Maintenance, ticket: loam.Ticket, completion: loam.ReadResult) !void {
        const value = backing(self);
        if (value.read.hasPendingRead()) return value.read.completeRead(ticket, completion);
        if (value.load.pending != null) {
            value.load.complete(value.read.store, ticket, completion) catch |err| {
                if (err == error.Gone and value.read.header.maintenance.phase == .identities) return;
                return err;
            };
            return;
        }
        if (value.query) |*query| if (query.load.pending != null) return query.completeRead(ticket, completion);
        if (value.edit) |*edit| if (edit.load.pending != null) return edit.completeRead(ticket, completion);
        if (value.grant_child_edit) |*edit| if (edit.load.pending != null) return edit.completeRead(ticket, completion);
        if (value.probe) |*probe| if (probe.load.pending != null) return probe.load.complete(value.read.store, ticket, completion);
        if (value.cancellation) |cancellation| return cancellation.completeRead(ticket, completion);
        return error.StaleCompletion;
    }
    pub fn cancel(self: *Maintenance) !void {
        const value = backing(self);
        try value.read.cancel();
        try value.load.cancel(value.read.store);
        if (value.query) |*query| try query.load.cancel(value.read.store);
        if (value.edit) |*edit| try edit.cancel();
        if (value.grant_child_edit) |*edit| try edit.cancel();
        if (value.probe) |*probe| try probe.load.cancel(value.read.store);
        if (value.cancellation) |cancellation| try cancellation.cancel();
    }
    pub fn deinit(self: *Maintenance) !void {
        const value = backing(self);
        const store = value.read.store;
        const allocator = value.read.allocator;
        if (value.grant_child_edit) |edit| if (edit.load.pending != null) return error.Busy;
        if (value.read.hasPendingRead() or value.load.pending != null or (if (value.query) |query| query.load.pending != null else false) or (if (value.edit) |edit| edit.load.pending != null else false) or (if (value.probe) |probe| probe.load.pending != null else false)) return error.Busy;
        if (value.cancellation) |cancellation| try cancellation.deinit();
        if (value.lease) |lease| try store.release(lease);
        try value.read.deinit();
        allocator.destroy(value);
    }
};
fn backing(self: *Maintenance) *State {
    return @ptrCast(@alignCast(self));
}
