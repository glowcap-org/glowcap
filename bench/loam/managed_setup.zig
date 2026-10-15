//! Trusted setup and sharing through the shipped managed Store APIs.
const g = @import("glowcap");
const access = g.loam.access;
const core = access.core;
const storage = access.storage;

pub fn pump(self: anytype, operation: anytype) !void {
    for (0..512) |_| switch (try operation.advance()) {
        .ready => return,
        .read => |request| {
            self.reads += 1;
            try operation.completeRead(request.ticket, self.db.read(request));
        },
        .waiting => {},
    };
    return error.NoProgress;
}

pub fn resource(self: anytype, parent: ?core.ResourceId) !core.ResourceId {
    var read = try storage.Read.init(self.allocator, &self.store, self.owner, 32);
    defer read.deinit() catch unreachable;
    try pump(self, &read);
    try self.store.begin();
    errdefer if (self.store.phase == .staging) self.store.abort() catch unreachable;
    const id = try stageResource(self, &read, parent);
    try self.finish(try self.store.prepare());
    return id;
}

/// Stage one resource append inside the caller's open transaction. Several
/// calls over one `read` compose: each sees the directory pages and header the
/// earlier ones proposed.
pub fn stageResource(self: anytype, read: *storage.Read, parent: ?core.ResourceId) !core.ResourceId {
    var append = try storage.Append.init(read, .resource);
    defer append.deinit() catch unreachable;
    try pump(self, &append);
    for (0..512) |_| {
        const step = append.prepareResource(parent) catch |err| {
            if (err != error.RecordUnloaded) return err;
            try pump(self, read);
            continue;
        };
        switch (step) {
            .ready => break,
            .read => |request| {
                self.reads += 1;
                try append.completeRead(request.ticket, self.db.read(request));
            },
            .waiting => return error.UnexpectedWait,
        }
    }
    for (0..128) |_| {
        return storage.stage.appendResource(&append, @fromBackingInt(1), parent) catch |err| {
            if (err != error.RecordUnloaded) return err;
            try pump(self, read);
            continue;
        };
    }
    return error.NoProgress;
}

pub fn issue(self: anytype, command: core.GrantPlan.Command) !core.GrantId {
    var read = try storage.Read.init(self.allocator, &self.store, self.owner, 32);
    defer read.deinit() catch unreachable;
    try pump(self, &read);
    var plan: ?core.GrantPlan = null;
    for (0..128) |_| {
        var grants = try read.grantView();
        var resources = try read.resourceView();
        const fresh: core.GrantId = .{ .owner = read.header.owner, .slot = @intCast(read.header.next_grant), .generation = 1 };
        plan = core.GrantPlan.prepareCopying(self.allocator, &grants, &resources, &read.header.policy, read.header.max_grant_children, fresh, command) catch |err| {
            if (err != error.RecordUnloaded) return err;
            try pump(self, &read);
            continue;
        };
        break;
    }
    if (plan == null) return error.NoProgress;
    defer plan.?.deinit(self.allocator);
    for (0..128) |_| {
        read.prepareHistory() catch |err| {
            if (err != error.RecordUnloaded) return err;
            try pump(self, &read);
            continue;
        };
        break;
    } else return error.NoProgress;
    var append: ?storage.Append = if (plan.?.delta == .issue) try storage.Append.init(&read, .grant) else null;
    defer if (append) |*path| path.deinit() catch unreachable;
    if (append) |*path| {
        path.grant_parent = plan.?.delta.issue.parent;
        try pump(self, path);
    }
    try self.store.begin();
    errdefer if (self.store.phase == .staging) self.store.abort() catch unreachable;
    const result = try storage.stage.grant(&read, &plan.?, if (append) |*path| path else null);
    try self.finish(try self.store.prepare());
    return result.change.grant;
}

pub fn descriptor(self: anytype, grant: core.GrantId, powers: ?core.Control.Powers) !g.loam.core.ObjectId {
    var read = try storage.Read.init(self.allocator, &self.store, self.owner, 32);
    defer read.deinit() catch unreachable;
    try pump(self, &read);
    try self.store.begin();
    errdefer if (self.store.phase == .staging) self.store.abort() catch unreachable;
    for (0..128) |_| {
        const id = (if (powers) |value| self.capabilities.stageControl(&read, grant, value, false) else self.capabilities.stageUse(&read, grant, true)) catch |err| {
            if (err != error.RecordUnloaded) return err;
            try pump(self, &read);
            continue;
        };
        try self.finish(try self.store.prepare());
        return id;
    }
    return error.NoProgress;
}
