//! Resource lookup supplies data; the shared managed access scope evaluator owns the
//! answer. Fake unloaded rows model record demand, not asynchronous storage.
const structural_policy = @import("grant_fixture.zig").structural_policy;
const std = @import("std");
const f = @import("grant_fixture.zig");
const core = f.core;
const View = core.ResourceView;
const Id = core.ResourceId;

fn id(slot: u32) Id {
    return .{ .owner = @fromBackingInt(1), .slot = slot, .generation = 1 };
}
const Source = struct {
    version: View.Version = .{ .owner = @fromBackingInt(1), .revision = @fromBackingInt(4) },
    rows: [4]View.Record,
    loaded: [4]bool = .{ false, false, false, false },
    absent: ?u32 = null,
    calls: usize = 0,
    change_on_call: ?usize = null,
    fail: bool = false,

    fn init() Source {
        return .{ .rows = .{
            .{ .id = id(0), .kind = f.kind, .parent = null },
            .{ .id = id(1), .kind = f.kind, .parent = id(0) },
            .{ .id = id(2), .kind = f.kind, .parent = id(1) },
            .{ .id = id(3), .kind = f.kind, .parent = null },
        } };
    }

    fn view(self: *Source) View {
        return View.init(self.version, 3, self, read);
    }

    fn read(context: *const anyopaque, requested: Id) View.SourceError!View.Reply {
        const self: *Source = @ptrCast(@alignCast(@constCast(context)));
        self.calls += 1;
        if (self.fail) return error.ReadFailed;
        if (self.change_on_call == self.calls) self.version.revision = @fromBackingInt(5);
        const value: @FieldType(View.Reply, "value") = if (requested.slot >= self.rows.len)
            .{ .absent = .unknown }
        else if (!self.loaded[requested.slot])
            .unloaded
        else if (self.absent == requested.slot or requested.generation != 1)
            .{ .absent = .gone }
        else
            .{ .present = self.rows[requested.slot] };
        return .{ .version = self.version, .value = value };
    }
};

const Query = union(enum) {
    contains: struct { scope: core.Scope, target: Id },
    subset: struct { child: core.Scope, parent: core.Scope },

    fn run(self: Query, view: *View) core.Scope.Error!bool {
        return switch (self) {
            .contains => |q| q.scope.contains(view, q.target),
            .subset => |q| q.child.isSubsetOf(view, q.parent),
        };
    }
};

test "access resident and faulting resource views share scope answers" {
    const queries = [_]Query{
        .{ .contains = .{ .scope = .{ .owned_subtree = id(0) }, .target = id(2) } },
        .{ .contains = .{ .scope = .{ .owned_subtree = id(3) }, .target = id(2) } },
        .{ .contains = .{ .scope = .{ .objects = &.{ id(0), id(2) } }, .target = id(1) } },
        .{ .contains = .{ .scope = .{ .object = id(2) }, .target = id(2) } },
        .{ .subset = .{ .child = .{ .objects = &.{ id(1), id(2) } }, .parent = .{ .owned_subtree = id(0) } } },
        .{ .subset = .{ .child = .{ .owned_subtree = id(1) }, .parent = .{ .objects = &.{ id(1), id(2) } } } },
    };
    for (queries) |query| {
        var resident = Source.init();
        @memset(&resident.loaded, true);
        var resident_view = resident.view();
        const expected = try query.run(&resident_view);
        var cold = Source.init();
        var cold_view = cold.view();
        var misses: usize = 0;
        while (true) {
            const actual = query.run(&cold_view) catch |err| {
                try std.testing.expectEqual(error.RecordUnloaded, err);
                const request = cold_view.missing.?;
                try std.testing.expectEqualDeep(cold.version, request.version);
                try std.testing.expect(!cold.loaded[request.id.slot]);
                cold.loaded[request.id.slot] = true;
                misses += 1;
                try std.testing.expect(misses <= cold.rows.len);
                continue;
            };
            try std.testing.expectEqual(expected, actual);
            break;
        }
        try std.testing.expect(misses != 0);
    }
}

test "access unloaded resource is distinct from gone and unknown" {
    var source = Source.init();
    source.absent = 1;
    var view = source.view();
    try std.testing.expectError(error.RecordUnloaded, view.get(id(1)));
    try std.testing.expect(view.missing.?.id.eql(id(1)));
    source.loaded[1] = true;
    try std.testing.expectError(error.Gone, view.get(id(1)));
    try std.testing.expect(view.missing == null);
    try std.testing.expectError(error.UnknownResource, view.get(id(9)));
    const calls = source.calls;
    var invalid = id(0);
    invalid.owner = @fromBackingInt(2);
    try std.testing.expectError(error.ForeignOwner, view.get(invalid));
    invalid = id(0);
    invalid.generation = 0;
    try std.testing.expectError(error.UnknownResource, view.get(invalid));
    try std.testing.expectEqual(calls, source.calls);
    source.fail = true;
    try std.testing.expectError(error.ReadFailed, view.get(id(0)));
    try std.testing.expect(view.missing == null);
}

test "access resource views reject stale present absent and unloaded replies" {
    for (0..3) |mode| {
        var source = Source.init();
        var view = source.view();
        source.version.revision = @fromBackingInt(5);
        source.loaded[0] = mode != 0;
        if (mode == 2) source.absent = 0;
        try std.testing.expectError(error.RevisionConflict, view.get(id(0)));
        try std.testing.expect(view.missing == null);
        source.version = view.version;
        source.version.owner = @fromBackingInt(2);
        try std.testing.expectError(error.RevisionConflict, view.get(id(0)));
    }
    var source = Source.init();
    @memset(&source.loaded, true);
    source.change_on_call = 3;
    var view = source.view();
    try std.testing.expectError(error.RevisionConflict, view.isDescendant(id(2), id(0)));
}

test "access loaded records cannot substitute identity or malformed parent edges" {
    for (0..4) |mode| {
        var source = Source.init();
        @memset(&source.loaded, true);
        switch (mode) {
            0 => source.rows[1].id = id(2),
            1 => source.rows[1].parent.?.owner = @fromBackingInt(2),
            2 => source.rows[1].parent.?.generation = 0,
            3 => source.rows[1].parent = id(1),
            else => unreachable,
        }
        var view = source.view();
        try std.testing.expectError(error.InvalidRecord, view.get(id(1)));
    }
}

test "access positive subtree match cannot hide missing cyclic or overdeep ancestry" {
    var source = Source.init();
    source.loaded[2] = true;
    var view = source.view();
    try std.testing.expectError(error.RecordUnloaded, view.isDescendant(id(2), id(2)));
    try std.testing.expect(view.missing.?.id.eql(id(1)));
    @memset(&source.loaded, true);
    source.absent = 0;
    try std.testing.expectError(error.Gone, view.isDescendant(id(2), id(2)));
    source.absent = null;
    source.rows[0].parent = id(1);
    try std.testing.expectError(error.DepthLimit, view.isDescendant(id(2), id(2)));
    try std.testing.expect(source.calls < 20);
    source.rows[0].parent = null;
    view.max_depth = 1;
    try std.testing.expectError(error.DepthLimit, view.isDescendant(id(2), id(2)));
    view.max_depth = 2;
    try std.testing.expect(try view.isDescendant(id(2), id(2)));
}

test "access selected scope loads and validates members after an early match" {
    var source = Source.init();
    source.loaded[0] = true;
    var view = source.view();
    const selection: core.Scope = .{ .objects = &.{ id(0), id(3) } };
    try std.testing.expectError(error.RecordUnloaded, selection.contains(&view, id(0)));
    try std.testing.expect(view.missing.?.id.eql(id(3)));
    source.loaded[3] = true;
    source.absent = 3;
    try std.testing.expectError(error.Gone, selection.contains(&view, id(0)));
}

test "access resident graph views expire on reparent and allocate no read storage" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var graph = try f.graphInit(failing.allocator());
    defer graph.deinit() catch unreachable;
    const root = try graph.create(graph.revision(), &structural_policy, f.kind, null);
    const other = try graph.create(graph.revision(), &structural_policy, f.kind, null);
    const child = try graph.create(graph.revision(), &structural_policy, f.kind, root);
    var view = graph.readView();
    const allocations = failing.alloc_index;
    failing.fail_index = allocations;
    const subtree: core.Scope = .{ .owned_subtree = root };
    try std.testing.expect(try subtree.contains(&view, child));
    try graph.reparent(graph.revision(), &structural_policy, child, other);
    try std.testing.expectError(error.RevisionConflict, subtree.contains(&view, child));
    view = graph.readView();
    try std.testing.expect(!try subtree.contains(&view, child));
    try std.testing.expect(try graph.isDescendant(child, other));
    try std.testing.expectEqual(allocations, failing.alloc_index);
}
