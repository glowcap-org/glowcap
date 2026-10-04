//! Whole-module exports on the supported Zig consumer namespaces.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;

const Surface = struct {
    path: []const u8,
    modules: []const []const u8,
};

/// Whole modules intentionally reachable through each supported consumer root.
/// Names are qualified through public container namespaces and sorted so a
/// review sees the API change rather than an opaque fingerprint.
const surfaces = [_]Surface{
    .{ .path = "src/root.zig", .modules = &.{
        "actors",
        "driver",
        "foundation",
        "loam",
        "net",
        "ocapn.codec",
        "ocapn.engine",
        "ocapn.model",
        "ocapn.session",
    } },
    .{ .path = "src/loam/mod.zig", .modules = &.{ "access", "collections", "core", "hosting", "records" } },
    .{ .path = "src/loam/hosting/mod.zig", .modules = &.{ "publication", "references" } },
    .{ .path = "src/loam/core/mod.zig", .modules = &.{} },
    .{ .path = "src/loam/records/mod.zig", .modules = &.{} },
    .{ .path = "src/loam/collections/mod.zig", .modules = &.{} },
    .{ .path = "src/loam/access/mod.zig", .modules = &.{ "core", "records", "storage", "hosting" } },
    .{ .path = "src/loam/access/core/mod.zig", .modules = &.{} },
    .{ .path = "src/loam/access/records/mod.zig", .modules = &.{"profile"} },
    .{ .path = "src/foundation/mod.zig", .modules = &.{
        "crypto",
        "failure_chain",
        "frame",
        "id",
        "noise",
        "sealed",
        "spill",
        "stream_framing",
        "thread_affinity",
    } },
    .{ .path = "src/ocapn/model/mod.zig", .modules = &.{
        "equality",
        "owned",
        "route_bundle",
        "transport",
        "uri",
        "view",
    } },
    .{ .path = "src/ocapn/codec/mod.zig", .modules = &.{
        "capnp",
        "dispatch",
        "framing",
        "order",
        "registry",
        "signed",
        "syrup",
    } },
    .{ .path = "src/ocapn/session/mod.zig", .modules = &.{
        "id_route",
        "inspect",
        "slot",
        "validate",
    } },
    .{ .path = "src/ocapn/engine/mod.zig", .modules = &.{
        "abort_projection",
        "bootstrap",
        "cross_peer",
        "events",
        "fetch",
        "handoff_gifter",
        "handoff_names",
        "handoff_recipient",
        "listen",
        "lower",
        "negotiation",
        "node_services",
        "pairing",
        "pipeline",
        "sturdyref",
        "v1_0",
    } },
    .{ .path = "src/actors/mod.zig", .modules = &.{"ocap"} },
    .{ .path = "src/net/mod.zig", .modules = &.{
        "carrier_failure",
        "clock",
        "completion",
        "inproc",
        "multiplexed_resident",
        "netlayer",
        "noise_completion",
        "onion",
        "operation_owner",
        "poll",
        "readiness",
        "relay",
        "socket",
        "stream_shim",
        "sync",
        "tcp",
        "tls.engine",
        "tls.pollable_stream",
        "tls.runtime",
        "tls.runtime_owner",
        "tls.transform",
        "wake_channel",
        "websocket",
    } },
    .{ .path = "src/driver/mod.zig", .modules = &.{
        "core",
        "settle_mailbox",
    } },
};

const BindingKind = union(enum) {
    not_module,
    whole_module,
    alias: []const u8,
};

const Binding = struct {
    name: []const u8,
    kind: BindingKind,
    resolution_limit: usize,
};

pub fn check(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    for (surfaces) |surface| {
        const contents = root.readFileAlloc(io, surface.path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read Zig consumer module surface with {s}", .{ surface.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        const source = try gpa.dupeSentinel(u8, contents, 0);
        defer gpa.free(source);
        try checkSource(gpa, surface.path, source, surface.modules, violations);
    }
}

fn checkSource(
    gpa: std.mem.Allocator,
    path: []const u8,
    source: [:0]const u8,
    expected: []const []const u8,
    violations: *std.ArrayList([]const u8),
) !void {
    var tree = try std.zig.Ast.parse(gpa, source, .{ .mode = .zig });
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) {
        try appendViolation(gpa, violations, "{s}: could not parse the supported Zig consumer root for whole-module export inventory", .{path});
        return;
    }

    var bindings: std.ArrayList(Binding) = .empty;
    defer bindings.deinit(gpa);
    var actual: std.ArrayList([]const u8) = .empty;
    defer {
        for (actual.items) |name| gpa.free(name);
        actual.deinit(gpa);
    }
    try collectScope(gpa, &tree, tree.rootDecls(), "", &bindings, &actual);

    for (actual.items) |name| {
        if (!contains(expected, name)) try appendViolation(
            gpa,
            violations,
            "{s}: added whole-module consumer export `{s}`; only a consumer-intended API change updates the exact inventory in tools/check/source_check/project_shape/zig_module_surface.zig",
            .{ path, name },
        );
    }
    for (expected) |name| {
        if (!contains(actual.items, name)) try appendViolation(
            gpa,
            violations,
            "{s}: missing whole-module consumer export `{s}`; restore it, or update the exact inventory only for a consumer-intended API change",
            .{ path, name },
        );
    }
}

fn collectScope(
    gpa: std.mem.Allocator,
    tree: *const std.zig.Ast,
    members: []const std.zig.Ast.Node.Index,
    prefix: []const u8,
    bindings: *std.ArrayList(Binding),
    exports: *std.ArrayList([]const u8),
) !void {
    const binding_base = bindings.items.len;
    defer bindings.items.len = binding_base;

    // First collect every declaration in this lexical scope. Looking bindings
    // up from the end then gives a nested scope its ordinary shadowing rule.
    for (members) |member| {
        const decl = tree.fullVarDecl(member) orelse continue;
        const init = decl.ast.init_node.unwrap() orelse continue;
        try bindings.append(gpa, .{
            .name = tree.tokenSlice(decl.ast.mut_token + 1),
            .kind = bindingKind(tree, init),
            .resolution_limit = 0,
        });
    }
    const scope_end = bindings.items.len;
    for (bindings.items[binding_base..scope_end]) |*binding| binding.resolution_limit = scope_end;

    for (members) |member| {
        const decl = tree.fullVarDecl(member) orelse continue;
        if (decl.visib_token == null) continue;
        const init = decl.ast.init_node.unwrap() orelse continue;
        const name = tree.tokenSlice(decl.ast.mut_token + 1);

        if (isWholeImport(tree, init) or resolvesToWholeModule(tree, init, bindings.items)) {
            try appendQualified(gpa, exports, prefix, name);
        }

        var container_buffer: [2]std.zig.Ast.Node.Index = undefined;
        const container = tree.fullContainerDecl(&container_buffer, init) orelse continue;
        const nested_prefix = try qualify(gpa, prefix, name);
        defer gpa.free(nested_prefix);
        try collectScope(gpa, tree, container.ast.members, nested_prefix, bindings, exports);
    }
}

fn isWholeImport(tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) bool {
    var params_buffer: [2]std.zig.Ast.Node.Index = undefined;
    const params = tree.builtinCallParams(&params_buffer, node) orelse return false;
    return params.len == 1 and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import");
}

fn resolvesToWholeModule(
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    bindings: []const Binding,
) bool {
    if (tree.nodeTag(node) != .identifier) return false;
    const name = tree.tokenSlice(tree.nodeMainToken(node));
    const index = findBinding(bindings, name, bindings.len) orelse return false;
    return bindingResolvesToWholeModule(bindings, index, bindings.len);
}

fn bindingKind(tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) BindingKind {
    if (isWholeImport(tree, node)) return .whole_module;
    if (tree.nodeTag(node) == .identifier) return .{ .alias = tree.tokenSlice(tree.nodeMainToken(node)) };
    return .not_module;
}

fn findBinding(bindings: []const Binding, name: []const u8, limit: usize) ?usize {
    var index = limit;
    while (index != 0) {
        index -= 1;
        if (std.mem.eql(u8, bindings[index].name, name)) return index;
    }
    return null;
}

fn bindingResolvesToWholeModule(bindings: []const Binding, index: usize, fuel: usize) bool {
    if (fuel == 0) return false;
    return switch (bindings[index].kind) {
        .not_module => false,
        .whole_module => true,
        .alias => |name| bindingResolvesToWholeModule(
            bindings,
            findBinding(bindings, name, bindings[index].resolution_limit) orelse return false,
            fuel - 1,
        ),
    };
}

fn appendQualified(
    gpa: std.mem.Allocator,
    exports: *std.ArrayList([]const u8),
    prefix: []const u8,
    name: []const u8,
) !void {
    const qualified = try qualify(gpa, prefix, name);
    errdefer gpa.free(qualified);
    if (contains(exports.items, qualified)) {
        gpa.free(qualified);
        return;
    }
    try exports.append(gpa, qualified);
}

fn qualify(gpa: std.mem.Allocator, prefix: []const u8, name: []const u8) ![]u8 {
    return if (prefix.len == 0)
        gpa.dupe(u8, name)
    else
        std.fmt.allocPrint(gpa, "{s}.{s}", .{ prefix, name });
}

fn contains(names: []const []const u8, needle: []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, name, needle)) return true;
    return false;
}

fn freeViolations(gpa: std.mem.Allocator, violations: *std.ArrayList([]const u8)) void {
    for (violations.items) |violation| gpa.free(violation);
    violations.deinit(gpa);
}

test "an extra whole-module alias is rejected by name" {
    const source: [:0]const u8 =
        \\const internal = @import(
        \\    "internal.zig",
        \\);
        \\const middle = internal;
        \\pub const supported = @import("supported.zig");
        \\pub const leaked = middle;
    ;
    var violations: std.ArrayList([]const u8) = .empty;
    defer freeViolations(std.testing.allocator, &violations);
    try checkSource(std.testing.allocator, "sample.zig", source, &.{"supported"}, &violations);
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
    try std.testing.expect(std.mem.indexOf(u8, violations.items[0], "added whole-module consumer export `leaked`") != null);
}

test "member selection from an imported module is not a module export" {
    const source: [:0]const u8 =
        \\const model = @import("model");
        \\const cycle_a = cycle_b;
        \\const cycle_b = cycle_a;
        \\pub const BrokenRef = model.BreakReason;
        \\pub const Error = @import("errors.zig").Error;
        \\pub const Cycle = cycle_a;
    ;
    var violations: std.ArrayList([]const u8) = .empty;
    defer freeViolations(std.testing.allocator, &violations);
    try checkSource(std.testing.allocator, "sample.zig", source, &.{}, &violations);
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "public containers qualify exports and nearest scope shadows aliases" {
    const source: [:0]const u8 =
        \\const leaf = @import("outer.zig");
        \\const forwarded = leaf;
        \\pub const direct = leaf;
        \\pub const nested = struct {
        \\    const leaf = 1;
        \\    pub const ignored = leaf;
        \\    pub const inherited = forwarded;
        \\    pub const included = @import("inner.zig");
        \\};
    ;
    var violations: std.ArrayList([]const u8) = .empty;
    defer freeViolations(std.testing.allocator, &violations);
    try checkSource(
        std.testing.allocator,
        "sample.zig",
        source,
        &.{ "direct", "nested.included", "nested.inherited" },
        &violations,
    );
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}
