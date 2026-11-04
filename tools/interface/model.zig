//! Checked description graph shared by emitters. The first projection selects
//! one receipt method with a bounded string argument and a capability result.
const std = @import("std");
const description = @import("description.zig");
const Node = description.Node;
const Error = description.Error;
const call_type = @import("call_type.zig");

pub const max_definitions: usize = 4096;
pub const max_parameters: usize = 256;

/// The narrow Zig creation checker spells this method's name and refuses
/// creation projected from any other method.
pub const creation_method = "add";

pub const Creation = struct {
    wire_name: []const u8,
    minimum: usize,
    maximum: usize,
};

const Normalized = struct { kind: call_type.Type, height: usize = 0 };
const Memo = struct {
    state: enum { unseen, visiting, complete } = .unseen,
    depth: usize = 0,
    value: Normalized = undefined,
};

pub const Model = struct {
    arena_allocator: std.mem.Allocator,
    memo: []Memo,
    definitions: Node,
    remaining: usize = 1 << 20,
    receipt_convention: bool = false,
    diagnostic: ?*?Node = null,

    /// The caller owns an arena lasting through method selection and emission.
    pub fn init(arena_allocator: std.mem.Allocator, root: Node) Error!Model {
        return initWithDiagnostic(arena_allocator, root, null);
    }

    /// Capture the first rejected node during initialization only.
    pub fn initDiagnostic(arena_allocator: std.mem.Allocator, root: Node, diagnostic: *?Node) Error!Model {
        diagnostic.* = null;
        return initWithDiagnostic(arena_allocator, root, diagnostic);
    }

    fn mark(self: *Model, node: Node) void {
        if (node.source.len == 0) return;
        if (self.diagnostic) |diagnostic| {
            if (diagnostic.* == null) diagnostic.* = node;
        }
    }

    fn initWithDiagnostic(arena_allocator: std.mem.Allocator, root: Node, diagnostic: ?*?Node) Error!Model {
        errdefer if (diagnostic) |failed| {
            if (failed.* == null) failed.* = root;
        };
        const fields = try root.fields("glowcap:interface", 3);
        if (try fields[0].number() != 1 or fields[1].kind != .dictionary or fields[2].kind != .dictionary) return error.InvalidDescription;
        if (fields[2].children.len > 2 * max_definitions) return error.ResourceLimit;
        const memo = try arena_allocator.alloc(Memo, fields[2].children.len / 2);
        @memset(memo, .{});
        var self: Model = .{ .arena_allocator = arena_allocator, .memo = memo, .definitions = fields[2], .receipt_convention = try checkProfiles(fields[1]), .diagnostic = diagnostic };
        var i: usize = 0;
        while (i < self.definitions.children.len) : (i += 2) {
            try identifier(try self.definitions.children[i].string());
            const declaration = self.definitions.children[i + 1];
            errdefer self.mark(declaration);
            if (declaration.kind != .record or declaration.children.len != 1) return error.InvalidDescription;
            if (std.mem.eql(u8, declaration.bytes, "type")) {
                try self.checkType(declaration.children[0], 0);
                _ = try self.resolve(declaration.children[0]);
            } else if (std.mem.eql(u8, declaration.bytes, "interface")) {
                try self.checkInterface(declaration.children[0]);
            } else return error.InvalidDescription;
        }
        self.diagnostic = null;
        return self;
    }

    // Declared profiles are build requirements, including when not used.
    // Return the receipt permission only after validating every declaration.
    fn checkProfiles(profiles: Node) Error!bool {
        if (profiles.children.len % 2 != 0) return error.InvalidDescription;
        var values = false;
        var receipts = false;
        var i: usize = 0;
        while (i < profiles.children.len) : (i += 2) {
            const name = try profiles.children[i].string();
            if (try profiles.children[i + 1].number() != 1) return error.InvalidDescription;
            if (std.mem.eql(u8, name, "glowcap.values")) {
                if (values) return error.InvalidDescription;
                values = true;
            } else if (std.mem.eql(u8, name, "loam.receipt")) {
                if (receipts) return error.InvalidDescription;
                receipts = true;
            } else return error.InvalidDescription;
        }
        if (!values) return error.InvalidDescription;
        return receipts;
    }

    fn definition(self: *Model, name: []const u8) Error!Node {
        try self.spend(self.definitions.children.len / 2);
        return self.definitions.get(name);
    }

    fn spend(self: *Model, work: usize) Error!void {
        if (work > self.remaining) return error.ResourceLimit;
        self.remaining -= work;
    }

    pub fn resolve(self: *Model, input: Node) Error!Node {
        errdefer self.mark(input);
        var value = input;
        var hops: usize = 0;
        while (value.kind == .record and std.mem.eql(u8, value.bytes, "ref")) {
            if (hops >= self.definitions.children.len / 2) return error.InvalidDescription;
            hops += 1;
            const reference = try value.fields("ref", 1);
            const declaration = self.definition(try reference[0].string()) catch |err| {
                self.mark(value);
                return err;
            };
            if (std.mem.eql(u8, declaration.bytes, "interface")) return declaration;
            value = (try declaration.fields("type", 1))[0];
        }
        return value;
    }

    fn checkInterface(self: *Model, methods: Node) Error!void {
        errdefer self.mark(methods);
        if (methods.kind != .dictionary) return error.InvalidDescription;
        var i: usize = 0;
        while (i < methods.children.len) : (i += 2) {
            const name = methods.children[i];
            if (name.kind != .string and !(name.kind == .boolean and !name.boolean)) return error.InvalidDescription;
            // Current language scope chooses one raw-list signature or named methods.
            if (name.kind == .boolean and methods.children.len != 2) return error.InvalidDescription;
            const signature = try methods.children[i + 1].fields("method", 3);
            const params = signature[0];
            if (params.kind != .list or params.children.len > max_parameters) return error.InvalidDescription;
            if (!signature[2].is("call") and !signature[2].is("tell") and !signature[2].is("loam.receipt")) return error.InvalidDescription;
            if (signature[2].is("loam.receipt") and (!self.receipt_convention or name.kind != .string)) return error.InvalidDescription;
            if (signature[2].is("tell") and !signature[1].is("undefined")) return error.InvalidDescription;
            var optional = false;
            for (params.children, 0..) |param, at| {
                errdefer self.mark(param);
                if (param.kind != .record) return error.InvalidDescription;
                const rest = std.mem.eql(u8, param.bytes, "rest");
                const fields = try param.fields(if (rest) "rest" else "parameter", if (rest) 2 else 3);
                try identifier(try fields[0].string());
                for (params.children[0..at]) |previous| {
                    if (std.mem.eql(u8, previous.children[0].bytes, fields[0].bytes)) return error.InvalidDescription;
                }
                if (rest) {
                    if (optional or at + 1 != params.children.len) return error.InvalidDescription;
                } else {
                    if (fields[2].kind != .boolean or (optional and !fields[2].boolean)) return error.InvalidDescription;
                    optional = fields[2].boolean;
                }
                try self.checkType(fields[1], 0);
            }
            try self.checkType(signature[1], 0);
        }
    }

    fn checkType(self: *Model, value: Node, depth: usize) Error!void {
        errdefer self.mark(value);
        try self.spend(1);
        if (depth > description.max_depth) return error.ResourceLimit;
        if (value.kind == .symbol) {
            for ([_][]const u8{ "undefined", "null", "bool", "integer", "float64", "string", "bytes", "symbol", "target", "value", "error", "keyword", "float32" }) |name| {
                if (value.is(name)) return;
            }
            return error.InvalidDescription;
        }
        if (value.kind != .record) return error.InvalidDescription;
        const label = value.bytes;
        if (std.mem.eql(u8, label, "ref")) {
            const fields = try value.fields("ref", 1);
            _ = try self.definition(try fields[0].string());
        } else if (std.mem.eql(u8, label, "bounded")) {
            const fields = try value.fields("bounded", 2);
            try self.checkType(fields[0], depth + 1);
            _ = try self.constrained(value);
        } else if (std.mem.eql(u8, label, "list") or std.mem.eql(u8, label, "set") or std.mem.eql(u8, label, "promise")) {
            try self.checkType((try value.fields(label, 1))[0], depth + 1);
        } else if (std.mem.eql(u8, label, "tuple") or std.mem.eql(u8, label, "union")) {
            const members = (try value.fields(label, 1))[0];
            if (members.kind != .list) return error.InvalidDescription;
            if (std.mem.eql(u8, label, "union")) return error.UnsupportedProjection;
            for (members.children) |member| try self.checkType(member, depth + 1);
        } else if (std.mem.eql(u8, label, "record") or std.mem.eql(u8, label, "tagged")) {
            const fields = try value.fields(label, 2);
            _ = try fields[0].string();
            if (std.mem.eql(u8, label, "tagged")) {
                try self.checkType(fields[1], depth + 1);
            } else {
                if (fields[1].kind != .list) return error.InvalidDescription;
                for (fields[1].children) |field| try self.checkType(field, depth + 1);
            }
        } else return error.UnsupportedProjection;
    }

    const Constrained = struct { base: Node, limits: call_type.IntegerBounds };

    // Follow only aliases and bound wrappers. A copied container terminates
    // this chain, so returning to a wrapper is unproductive recursion.
    fn constrained(self: *Model, input: Node) Error!Constrained {
        errdefer self.mark(input);
        var layers: [description.max_depth]Node = undefined;
        var visited: [description.max_depth][*]const Node = undefined;
        var count: usize = 0;
        var base = try self.resolve(input);
        while (base.kind == .record and std.mem.eql(u8, base.bytes, "bounded")) {
            try self.spend(count + 1);
            for (visited[0..count]) |previous| if (previous == base.children.ptr) return error.InvalidDescription;
            if (count == layers.len) return error.ResourceLimit;
            const fields = try base.fields("bounded", 2);
            visited[count] = base.children.ptr;
            layers[count] = fields[1];
            count += 1;
            base = try self.resolve(fields[0]);
        }
        var result = try self.bounds(base, .{ .kind = .dictionary });
        for (layers[0..count]) |layer| {
            const next = try self.bounds(base, layer);
            if (next.min) |minimum| result.min = if (result.min) |previous| @max(previous, minimum) else minimum;
            if (next.max) |maximum| result.max = if (result.max) |previous| @min(previous, maximum) else maximum;
            if (result.min) |minimum| if (result.max) |maximum| {
                if (minimum > maximum) return error.InvalidDescription;
            };
        }
        return .{ .base = base, .limits = result };
    }

    // One interpretation of bound names and units for validation and call projection.
    fn bounds(self: *Model, base: Node, restrictions: Node) Error!call_type.IntegerBounds {
        errdefer self.mark(restrictions);
        if (restrictions.kind != .dictionary) return error.InvalidDescription;
        const integers = base.is("integer");
        const bytes = base.is("string") or base.is("bytes");
        const container = base.kind == .record and (std.mem.eql(u8, base.bytes, "list") or std.mem.eql(u8, base.bytes, "map") or std.mem.eql(u8, base.bytes, "set"));
        if (!integers and !bytes and !container) return error.InvalidDescription;
        var result: call_type.IntegerBounds = .{ .min = if (integers) null else 0 };
        var i: usize = 0;
        while (i < restrictions.children.len) : (i += 2) {
            errdefer self.mark(restrictions.children[i]);
            const key = try restrictions.children[i].string();
            const number = try restrictions.children[i + 1].number();
            const lower = std.mem.eql(u8, key, if (integers) "min" else "min_bytes");
            const upper = std.mem.eql(u8, key, if (integers) "max" else if (bytes) "max_bytes" else "max_items");
            if ((!lower and !upper) or (container and lower) or (!integers and number < 0)) return error.InvalidDescription;
            if (lower) result.min = number else result.max = number;
        }
        if (result.min) |minimum| if (result.max) |maximum| {
            if (minimum > maximum) return error.InvalidDescription;
        };
        return result;
    }

    /// Normalized nodes and parameter arrays belong to the caller's arena.
    pub fn callType(self: *Model, input: Node) !call_type.Type {
        return (try self.normalize(input, 0, 0)).kind;
    }

    fn normalize(self: *Model, input: Node, depth: usize, hops: usize) !Normalized {
        try self.spend(1);
        if (depth > description.max_depth or hops > description.max_depth) return error.ResourceLimit;
        if (input.kind == .record and std.mem.eql(u8, input.bytes, "ref")) {
            const name = try (try input.fields("ref", 1))[0].string();
            try self.spend(self.memo.len);
            var index: usize = 0;
            while (index < self.memo.len) : (index += 1) {
                if (std.mem.eql(u8, self.definitions.children[index * 2].bytes, name)) break;
            }
            if (index == self.memo.len) return error.InvalidDescription;
            const memo = &self.memo[index];
            switch (memo.state) {
                .visiting => return if (depth == memo.depth) error.InvalidDescription else error.UnsupportedProjection,
                .complete => {
                    if (hops + memo.value.height > description.max_depth) return error.ResourceLimit;
                    return memo.value;
                },
                .unseen => {},
            }
            const declaration = self.definitions.children[index * 2 + 1];
            if (std.mem.eql(u8, declaration.bytes, "interface")) return .{ .kind = .target };
            memo.state = .visiting;
            memo.depth = depth;
            errdefer memo.state = .unseen;
            memo.value = try self.normalize((try declaration.fields("type", 1))[0], depth, hops + 1);
            memo.value.height += 1;
            memo.state = .complete;
            return memo.value;
        }
        const node = input;
        if (node.is("string")) return .{ .kind = .{ .text = .{} } };
        if (node.is("integer")) return .{ .kind = .{ .integer = .{} } };
        if (node.is("bytes")) return .{ .kind = .{ .bytes = .{} } };
        if (node.is("bool")) return .{ .kind = .boolean };
        if (node.is("symbol")) return .{ .kind = .symbol };
        if (node.is("float64")) return .{ .kind = .float64 };
        if (node.is("error")) return .{ .kind = .error_value };
        if (node.is("undefined")) return .{ .kind = .nothing };
        if (node.is("null")) return error.UnsupportedTarget;
        if (node.is("value")) return .{ .kind = .value };
        if (node.is("target")) return .{ .kind = .target };
        if (node.kind != .record) return error.UnsupportedProjection;
        if (std.mem.eql(u8, node.bytes, "bounded")) {
            const fields = try node.fields("bounded", 2);
            var normalized = try self.normalize(fields[0], depth, hops + 1);
            normalized.height += 1;
            const effective = try self.constrained(node);
            const base = effective.base;
            const limits = effective.limits;
            if (base.is("integer")) return .{ .kind = .{ .integer = limits }, .height = normalized.height };
            if (base.is("string") or base.is("bytes")) {
                const bytes: call_type.ByteBounds = .{ .min = @intCast(limits.min.?), .max = if (limits.max) |max| @intCast(max) else null };
                return .{ .kind = if (base.is("string")) .{ .text = bytes } else .{ .bytes = bytes }, .height = normalized.height };
            }
            if (normalized.kind != .list) return error.UnsupportedProjection;
            const list = try self.arena_allocator.create(call_type.List);
            list.* = .{ .element = normalized.kind.list.element, .max_items = if (limits.max) |max| @intCast(max) else null };
            normalized.kind = .{ .list = list };
            return normalized;
        }
        if (std.mem.eql(u8, node.bytes, "promise")) {
            const fulfilled = try self.normalize((try node.fields("promise", 1))[0], depth, hops + 1);
            if (fulfilled.kind == .value) return .{ .kind = .pending_value, .height = fulfilled.height + 1 };
            if (fulfilled.kind == .target) return .{ .kind = .pending_target, .height = fulfilled.height + 1 };
            return error.UnsupportedProjection;
        }
        if (std.mem.eql(u8, node.bytes, "list")) {
            const child = try self.normalize((try node.fields("list", 1))[0], depth + 1, hops + 1);
            const list = try self.arena_allocator.create(call_type.List);
            list.* = .{ .element = child.kind };
            return .{ .kind = .{ .list = list }, .height = child.height + 1 };
        }
        const record = std.mem.eql(u8, node.bytes, "record");
        const tagged = std.mem.eql(u8, node.bytes, "tagged");
        if (record or tagged or std.mem.eql(u8, node.bytes, "tuple")) {
            const fields = try node.fields(node.bytes, if (record or tagged) 2 else 1);
            const members = fields[if (record or tagged) 1 else 0];
            if (!tagged and members.kind != .list) return error.InvalidDescription;
            const children = if (tagged) fields[1..2] else members.children;
            const types = try self.arena_allocator.alloc(call_type.Type, children.len);
            var height: usize = 0;
            for (children, types) |member, *kind| {
                const child = try self.normalize(member, depth + 1, hops + 1);
                kind.* = child.kind;
                height = @max(height, child.height);
            }
            if (record or tagged) {
                const result = try self.arena_allocator.create(call_type.Record);
                result.* = .{ .tag = try fields[0].string(), .fields = types };
                return .{ .kind = .{ .record = result }, .height = if (types.len == 0) 0 else height + 1 };
            }
            const result = try self.arena_allocator.create(call_type.Tuple);
            result.* = .{ .fields = types };
            return .{ .kind = .{ .tuple = result }, .height = if (types.len == 0) 0 else height + 1 };
        }
        return error.UnsupportedProjection;
    }

    /// Select a checked method while preserving positional versus symbolic invocation.
    pub fn method(self: *Model, interface_name: []const u8, selector: ?[]const u8) Error![]const Node {
        const interface = try (try self.definition(interface_name)).fields("interface", 1);
        const methods = interface[0].children;
        try self.spend(methods.len / 2);
        var i: usize = 0;
        while (i < methods.len) : (i += 2) {
            const key = methods[i];
            const matches = if (selector) |name|
                key.kind == .string and std.mem.eql(u8, key.bytes, name)
            else
                key.kind == .boolean and !key.boolean;
            if (matches) return methods[i + 1].fields("method", 3);
        }
        return error.InvalidDescription;
    }

    pub fn creation(self: *Model, interface_name: []const u8, method_name: []const u8) !Creation {
        const selected = try self.method(interface_name, method_name);
        if (!selected[2].is("loam.receipt") or selected[0].children.len != 1) return error.UnsupportedProjection;
        const param = try selected[0].children[0].fields("parameter", 3);
        if (param[2].boolean) return error.UnsupportedProjection;
        const input = self.callType(param[1]) catch |err| {
            return if (err == error.UnsupportedTarget) error.UnsupportedProjection else err;
        };
        if (input != .text) return error.UnsupportedProjection;
        const maximum = input.text.max orelse return error.UnsupportedProjection;
        const result = try self.resolve(selected[1]);
        if (result.kind != .record or !std.mem.eql(u8, result.bytes, "interface")) return error.UnsupportedProjection;
        return .{ .wire_name = method_name, .minimum = std.math.cast(usize, input.text.min) orelse return error.UnsupportedProjection, .maximum = std.math.cast(usize, maximum) orelse return error.UnsupportedProjection };
    }
};

fn identifier(name: []const u8) Error!void {
    if (name.len == 0) return error.InvalidDescription;
    var first = true;
    for (name) |c| {
        if (c == '.') {
            if (first) return error.InvalidDescription;
            first = true;
        } else {
            if (!(std.ascii.isAlphabetic(c) or c == '_' or (!first and std.ascii.isDigit(c)))) return error.InvalidDescription;
            first = false;
        }
    }
    if (first) return error.InvalidDescription;
}

test "checked call types retain Tasks bounds through aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var checked = try Model.init(a, try description.read(a, @embedFile("contract")));
    const name = try checked.callType(try description.read(a, "<3'ref10\"tasks.Name>"));
    try std.testing.expectEqual(@as(u64, 1), name.text.min);
    try std.testing.expectEqual(@as(?u64, 64), name.text.max);
    const text = try checked.callType(try description.read(a, "<3'ref10\"tasks.Text>"));
    try std.testing.expectEqual(@as(u64, 1), text.text.min);
    try std.testing.expectEqual(@as(?u64, 4096), text.text.max);
    const count = try checked.callType(try description.read(a, "<3'ref15\"tasks.TaskCount>"));
    try std.testing.expectEqual(@as(?i64, 0), count.integer.min);
    try std.testing.expectEqual(@as(?i64, 256), count.integer.max);
    const index = try checked.callType(try description.read(a, "<3'ref11\"tasks.Index>"));
    try std.testing.expectEqual(@as(?i64, 0), index.integer.min);
    try std.testing.expectEqual(@as(?i64, std.math.maxInt(i64)), index.integer.max);
    const target = try checked.callType(try description.read(a, "<3'ref14\"tasks.TaskList>"));
    try std.testing.expect(target == .target);
    const pending = try checked.callType(try description.read(a, "<7'promise<3'ref10\"tasks.Task>>"));
    try std.testing.expect(pending == .pending_target);
}

test "checked call integers preserve absent endpoints and exact signed extrema" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var checked = try Model.init(a, try description.read(a, "<17'glowcap:interface1+{14\"glowcap.values1+}{}>"));
    const unbounded = try checked.callType(try description.read(a, "7'integer"));
    try std.testing.expectEqual(@as(?i64, null), unbounded.integer.min);
    try std.testing.expectEqual(@as(?i64, null), unbounded.integer.max);
    const lower = try checked.callType(try description.read(a, "<7'bounded7'integer{3\"min0+}>"));
    try std.testing.expectEqual(@as(?i64, 0), lower.integer.min);
    try std.testing.expectEqual(@as(?i64, null), lower.integer.max);
    const upper = try checked.callType(try description.read(a, "<7'bounded7'integer{3\"max3+}>"));
    try std.testing.expectEqual(@as(?i64, null), upper.integer.min);
    try std.testing.expectEqual(@as(?i64, 3), upper.integer.max);
    const full = try checked.callType(try description.read(a, "<7'bounded7'integer{3\"max9223372036854775807+3\"min9223372036854775808-}>"));
    try std.testing.expectEqual(@as(?i64, std.math.minInt(i64)), full.integer.min);
    try std.testing.expectEqual(@as(?i64, std.math.maxInt(i64)), full.integer.max);
    const wide = try checked.callType(try description.read(a, "<7'bounded6'string{9\"max_bytes9223372036854775807+}>"));
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(i64)), wide.text.max);
    const string = try checked.callType(try description.read(a, "6'string"));
    try std.testing.expectEqual(@as(u64, 0), string.text.min);
    try std.testing.expectEqual(@as(?u64, null), string.text.max);
    for ([_][]const u8{
        "<7'bounded6'string{9\"max_bytes1-}>",
        "<7'bounded6'string{9\"max_bytes1+9\"min_bytes2+}>",
        "<7'bounded7'integer{3\"max1+3\"min2+}>",
        "<7'bounded7'integer{9\"max_bytes1+}>",
    }) |invalid| try std.testing.expectError(error.InvalidDescription, checked.callType(try description.read(a, invalid)));
    try std.testing.expectError(error.UnsupportedTarget, checked.callType(try description.read(a, "4'null")));
    try std.testing.expect((try checked.callType(try description.read(a, "5'bytes"))) == .bytes);
    const wide_bytes = try checked.callType(try description.read(a, "<7'bounded5'bytes{9\"max_bytes9223372036854775807+9\"min_bytes1+}>"));
    try std.testing.expectEqual(@as(u64, 1), wide_bytes.bytes.min);
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(i64)), wide_bytes.bytes.max);
}

test "checked call alias chains preserve the final scalar restriction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = "<17'glowcap:interface1+{14\"glowcap.values1+}{1\"A<4'type<3'ref1\"B>>1\"B<4'type<7'bounded6'string{9\"max_bytes64+9\"min_bytes1+}>>}>";
    var checked = try Model.init(a, try description.read(a, bytes));
    const alias = try checked.callType(try description.read(a, "<3'ref1\"A>"));
    try std.testing.expectEqual(@as(u64, 1), alias.text.min);
    try std.testing.expectEqual(@as(?u64, 64), alias.text.max);
}

test "bounded aliases intersect restrictions instead of widening or refusing them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prefix = "<17'glowcap:interface1+{14\"glowcap.values1+}{1\"A<4'type<7'bounded";
    const middle = ">>1\"B<4'type<7'bounded<3'ref1\"A>";
    const suffix = ">>}>";
    for ([_]struct { base: []const u8, first: []const u8, second: []const u8, maximum: u64 = 64 }{
        .{ .base = "6'string", .first = "{9\"max_bytes64+9\"min_bytes1+}", .second = "{9\"max_bytes128+9\"min_bytes4+}" },
        .{ .base = "5'bytes", .first = "{9\"max_bytes64+9\"min_bytes1+}", .second = "{9\"max_bytes128+9\"min_bytes4+}" },
        .{ .base = "7'integer", .first = "{3\"max64+3\"min1+}", .second = "{3\"max128+3\"min4+}" },
        .{ .base = "<4'list6'symbol>", .first = "{9\"max_items64+}", .second = "{9\"max_items128+}" },
        .{ .base = "6'string", .first = "{9\"max_bytes64+9\"min_bytes1+}", .second = "{9\"max_bytes16+9\"min_bytes4+}", .maximum = 16 },
        .{ .base = "5'bytes", .first = "{9\"max_bytes64+9\"min_bytes1+}", .second = "{9\"max_bytes16+9\"min_bytes4+}", .maximum = 16 },
        .{ .base = "7'integer", .first = "{3\"max64+3\"min1+}", .second = "{3\"max16+3\"min4+}", .maximum = 16 },
        .{ .base = "<4'list6'symbol>", .first = "{9\"max_items64+}", .second = "{9\"max_items16+}", .maximum = 16 },
    }) |case| {
        const source = try std.mem.concat(a, u8, &.{ prefix, case.base, case.first, middle, case.second, suffix });
        var model = try Model.init(a, try description.read(a, source));
        const result = try model.callType(try description.read(a, "<3'ref1\"B>"));
        switch (result) {
            .text, .bytes => |limits| {
                try std.testing.expectEqual(@as(u64, 4), limits.min);
                try std.testing.expectEqual(@as(?u64, case.maximum), limits.max);
            },
            .integer => |limits| {
                try std.testing.expectEqual(@as(?i64, 4), limits.min);
                try std.testing.expectEqual(@as(?i64, @intCast(case.maximum)), limits.max);
            },
            .list => |list| try std.testing.expectEqual(@as(?u64, case.maximum), list.max_items),
            else => return error.UnexpectedType,
        }
    }
    const disjoint = prefix ++ "7'integer{3\"max3+}" ++ middle ++ "{3\"min4+}" ++ suffix;
    try std.testing.expectError(error.InvalidDescription, Model.init(a, try description.read(a, disjoint)));
}
