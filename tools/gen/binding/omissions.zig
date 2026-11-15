//! A binding's FFI omission policy, checked against the C symbol inventories
//! its generator renders.
//!
//! A policy is a list of tables, each a file under `bindings/ffi_omissions/`
//! that lists exports with the reason for leaving each out of a binding's FFI
//! table. A generator joins `shared.zig`, the exports every binding leaves
//! out, with its own binding's file. `Policy` checks the joined entries once
//! at compile time and names the offending entry and the file that holds it
//! when it refuses. Inventory completeness is a C fact that
//! `archive_contract.inventoryFault` checks when each archive compiles, which
//! `zig build check` always does, so this module checks only what the tables
//! themselves state.

const std = @import("std");

/// One policy entry, read from a table's anonymous struct literal, with the
/// path of the file that holds it.
const Entry = struct { name: []const u8, reason: []const u8, path: []const u8 };

/// The first policy fact a list breaks, with the export name it names and the
/// file that holds the entry.
const Fault = struct {
    kind: Kind,
    name: []const u8,
    path: []const u8,

    pub const Kind = enum { unknown, ambiguous, duplicate, empty_reason };

    pub fn message(comptime self: Fault) []const u8 {
        return self.path ++ ": omission of `" ++ self.name ++ "` " ++ switch (self.kind) {
            .unknown => "names no export in this generator's archives",
            .ambiguous => "names an export that more than one archive declares",
            .duplicate => "appears more than once",
            .empty_reason => "gives no reason",
        };
    }
};

/// A policy file and its path.
const Table = struct { path: []const u8, raw: type };

/// The tables one generator joins: `shared` (the exports every binding leaves
/// out) and `own` (one binding's file), each with its path from `source`
/// (`path` and `shared_path`, written by the build).
pub fn tables(comptime source: type, comptime shared: type, comptime own: type) [2]Table {
    return .{
        .{ .path = source.shared_path, .raw = shared },
        .{ .path = source.path, .raw = own },
    };
}

fn entryCount(comptime list: anytype) usize {
    var n: usize = 0;
    inline for (list) |table| n += table.raw.omissions.len;
    return n;
}

fn entriesOf(comptime list: anytype) [entryCount(list)]Entry {
    var entries: [entryCount(list)]Entry = undefined;
    var i: usize = 0;
    inline for (list) |table| {
        inline for (table.raw.omissions) |entry| {
            entries[i] = .{ .name = entry.name, .reason = entry.reason, .path = table.path };
            i += 1;
        }
    }
    return entries;
}

/// The first broken policy fact, or null when every entry gives a reason and
/// names exactly one inventory row across `archives`, once across all of
/// `list`.
fn fault(comptime list: anytype, comptime archives: anytype) ?Fault {
    comptime {
        @setEvalBranchQuota(2_000_000);
        const entries = entriesOf(list);
        for (entries, 0..) |entry, i| {
            if (std.mem.trim(u8, entry.reason, " \t\r\n").len == 0) return .{ .kind = .empty_reason, .name = entry.name, .path = entry.path };
            for (entries[0..i]) |prior| {
                if (std.mem.eql(u8, prior.name, entry.name)) return .{ .kind = .duplicate, .name = entry.name, .path = entry.path };
            }
            var matches: usize = 0;
            for (archives) |Archive| {
                for (Archive.symbols.symbols) |row| {
                    if (std.mem.eql(u8, entry.name, row.name)) matches += 1;
                }
            }
            if (matches == 0) return .{ .kind = .unknown, .name = entry.name, .path = entry.path };
            if (matches != 1) return .{ .kind = .ambiguous, .name = entry.name, .path = entry.path };
        }
        return null;
    }
}

/// The checked policy over `list`, the tables from `tables`, and `archives`,
/// the archive set one generator renders.
pub fn Policy(comptime list: anytype, comptime archives: anytype) type {
    if (comptime fault(list, archives)) |broken| @compileError(broken.message());
    return struct {
        const entries = entriesOf(list);

        /// Whether the binding leaves `name` out.
        pub fn omits(comptime name: []const u8) bool {
            @setEvalBranchQuota(50_000);
            for (entries) |entry| {
                if (std.mem.eql(u8, entry.name, name)) return true;
            }
            return false;
        }
    };
}

const Row = struct { name: []const u8 };
const First = struct {
    pub const symbols = struct {
        pub const symbols = [_]Row{.{ .name = "glowcap_first" }};
    };
};
const Second = struct {
    pub const symbols = struct {
        pub const symbols = [_]Row{.{ .name = "glowcap_second" }};
    };
};

const Source = struct {
    pub const shared_path = "shared.zig";
    pub const path = "own.zig";
};

fn expectFault(comptime expected: ?Fault, comptime list: anytype, comptime archives: anytype) !void {
    const got = comptime fault(list, archives);
    if (expected) |want| {
        const broken = got orelse return error.TestExpectedFault;
        try std.testing.expectEqual(want.kind, broken.kind);
        try std.testing.expectEqualStrings(want.name, broken.name);
        try std.testing.expectEqualStrings(want.path, broken.path);
    } else try std.testing.expect(got == null);
}

/// A one-table list over `raw`, as a generator without a shared table joins.
fn only(comptime path: []const u8, comptime raw: type) [1]Table {
    return .{.{ .path = path, .raw = raw }};
}

test "an omission policy omits exactly the names it lists, and an empty one omits none" {
    const Raw = struct {
        pub const omissions = .{
            .{ .name = "glowcap_first", .reason = "provided by the binding" },
            .{ .name = "glowcap_second", .reason = "unused" },
        };
    };
    const Empty = struct {
        pub const omissions = .{};
    };
    try expectFault(null, only("raw.zig", Raw), .{ First, Second });
    try expectFault(null, only("empty.zig", Empty), .{First});
    const checked = Policy(only("raw.zig", Raw), .{ First, Second });
    try std.testing.expect(comptime checked.omits("glowcap_first"));
    try std.testing.expect(comptime checked.omits("glowcap_second"));
    try std.testing.expect(comptime !checked.omits("glowcap_third"));
    try std.testing.expect(comptime !Policy(only("empty.zig", Empty), .{First}).omits("glowcap_first"));
}

test "a policy joins its tables and omits what either lists" {
    const Shared = struct {
        pub const omissions = .{.{ .name = "glowcap_first", .reason = "every binding" }};
    };
    const Own = struct {
        pub const omissions = .{.{ .name = "glowcap_second", .reason = "this binding" }};
    };
    const joined = Policy(tables(Source, Shared, Own), .{ First, Second });
    try std.testing.expect(comptime joined.omits("glowcap_first"));
    try std.testing.expect(comptime joined.omits("glowcap_second"));
    try std.testing.expect(comptime !joined.omits("glowcap_third"));
}

test "an omission policy refusal names the entry and the file that holds it" {
    const Stale = struct {
        pub const omissions = .{
            .{ .name = "glowcap_first", .reason = "unused" },
            .{ .name = "glowcap_removed", .reason = "unused" },
        };
    };
    const Duplicate = struct {
        pub const omissions = .{
            .{ .name = "glowcap_first", .reason = "unused" },
            .{ .name = "glowcap_first", .reason = "also unused" },
        };
    };
    const Blank = struct {
        pub const omissions = .{.{ .name = "glowcap_first", .reason = " \t\n" }};
    };
    const Empty = struct {
        pub const omissions = .{.{ .name = "glowcap_first", .reason = "" }};
    };
    const Single = struct {
        pub const omissions = .{.{ .name = "glowcap_second", .reason = "unused" }};
    };
    const Removed = struct {
        pub const omissions = .{.{ .name = "glowcap_removed", .reason = "unused" }};
    };
    const OmitsFirst = struct {
        pub const omissions = .{.{ .name = "glowcap_first", .reason = "unused" }};
    };
    try expectFault(.{ .kind = .unknown, .name = "glowcap_removed", .path = "a.zig" }, only("a.zig", Stale), .{First});
    try expectFault(.{ .kind = .unknown, .name = "glowcap_second", .path = "a.zig" }, only("a.zig", Single), .{First});
    try expectFault(.{ .kind = .duplicate, .name = "glowcap_first", .path = "a.zig" }, only("a.zig", Duplicate), .{First});
    try expectFault(.{ .kind = .empty_reason, .name = "glowcap_first", .path = "a.zig" }, only("a.zig", Blank), .{First});
    try expectFault(.{ .kind = .empty_reason, .name = "glowcap_first", .path = "a.zig" }, only("a.zig", Empty), .{First});
    try expectFault(.{ .kind = .ambiguous, .name = "glowcap_second", .path = "a.zig" }, only("a.zig", Single), .{ First, Second, Second });
    // Production joins `Shared` first, so an entry in `Own` names its own file.
    try expectFault(
        .{ .kind = .unknown, .name = "glowcap_removed", .path = "own.zig" },
        tables(Source, OmitsFirst, Removed),
        .{First},
    );
    try expectFault(
        .{ .kind = .duplicate, .name = "glowcap_first", .path = "own.zig" },
        tables(Source, OmitsFirst, OmitsFirst),
        .{First},
    );
    try std.testing.expectEqualStrings(
        "bindings/ffi_omissions/rust.zig: omission of `glowcap_removed` names no export in this generator's archives",
        comptime (Fault{ .kind = .unknown, .name = "glowcap_removed", .path = "bindings/ffi_omissions/rust.zig" }).message(),
    );
}
