//! A binding's FFI omission policy, checked against the C symbol inventories
//! its generator renders.
//!
//! A policy file under `bindings/ffi_omissions/` lists the exports one binding
//! leaves out of its FFI table, each with the reason for that decision.
//! `Policy` checks the list once at compile time and names the offending entry
//! and policy file when it refuses. Inventory completeness is a C fact that
//! `archive_contract.inventoryFault` checks when each archive compiles, which
//! `zig build check` always does, so this module checks only what the policy
//! itself states.

const std = @import("std");

/// One policy entry, read from the policy file's anonymous struct literal.
const Entry = struct { name: []const u8, reason: []const u8 };

/// The first policy fact a list breaks, with the export name it names.
const Fault = struct {
    kind: Kind,
    name: []const u8,

    pub const Kind = enum { unknown, ambiguous, duplicate, empty_reason };

    pub fn message(comptime self: Fault, comptime source: []const u8) []const u8 {
        return source ++ ": omission of `" ++ self.name ++ "` " ++ switch (self.kind) {
            .unknown => "names no export in this generator's archives",
            .ambiguous => "names an export that more than one archive declares",
            .duplicate => "appears more than once",
            .empty_reason => "gives no reason",
        };
    }
};

fn entriesOf(comptime raw: type) [raw.omissions.len]Entry {
    var entries: [raw.omissions.len]Entry = undefined;
    inline for (raw.omissions, 0..) |entry, i| entries[i] = .{ .name = entry.name, .reason = entry.reason };
    return entries;
}

/// The first broken policy fact, or null when every entry gives a reason and
/// names exactly one inventory row across `archives`, once.
fn fault(comptime raw: type, comptime archives: anytype) ?Fault {
    comptime {
        @setEvalBranchQuota(2_000_000);
        const entries = entriesOf(raw);
        for (entries, 0..) |entry, i| {
            if (std.mem.trim(u8, entry.reason, " \t\r\n").len == 0) return .{ .kind = .empty_reason, .name = entry.name };
            for (entries[0..i]) |prior| {
                if (std.mem.eql(u8, prior.name, entry.name)) return .{ .kind = .duplicate, .name = entry.name };
            }
            var matches: usize = 0;
            for (archives) |Archive| {
                for (Archive.symbols.symbols) |row| {
                    if (std.mem.eql(u8, entry.name, row.name)) matches += 1;
                }
            }
            if (matches == 0) return .{ .kind = .unknown, .name = entry.name };
            if (matches != 1) return .{ .kind = .ambiguous, .name = entry.name };
        }
        return null;
    }
}

/// The checked policy `raw` (a policy file) over `archives`, the archive set
/// one generator renders. `source` names the policy file in a refusal.
pub fn Policy(comptime source: []const u8, comptime raw: type, comptime archives: anytype) type {
    if (comptime fault(raw, archives)) |broken| @compileError(broken.message(source));
    return struct {
        const entries = entriesOf(raw);

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

fn expectFault(comptime expected: ?Fault, comptime raw: type, comptime archives: anytype) !void {
    const got = comptime fault(raw, archives);
    if (expected) |want| {
        const broken = got orelse return error.TestExpectedFault;
        try std.testing.expectEqual(want.kind, broken.kind);
        try std.testing.expectEqualStrings(want.name, broken.name);
    } else try std.testing.expect(got == null);
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
    try expectFault(null, Raw, .{ First, Second });
    try expectFault(null, Empty, .{First});
    const checked = Policy("raw.zig", Raw, .{ First, Second });
    try std.testing.expect(comptime checked.omits("glowcap_first"));
    try std.testing.expect(comptime checked.omits("glowcap_second"));
    try std.testing.expect(comptime !checked.omits("glowcap_third"));
    try std.testing.expect(comptime !Policy("empty.zig", Empty, .{First}).omits("glowcap_first"));
}

test "an omission policy refusal names the entry and its policy" {
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
    try expectFault(.{ .kind = .unknown, .name = "glowcap_removed" }, Stale, .{First});
    try expectFault(.{ .kind = .unknown, .name = "glowcap_second" }, Single, .{First});
    try expectFault(.{ .kind = .duplicate, .name = "glowcap_first" }, Duplicate, .{First});
    try expectFault(.{ .kind = .empty_reason, .name = "glowcap_first" }, Blank, .{First});
    try expectFault(.{ .kind = .empty_reason, .name = "glowcap_first" }, Empty, .{First});
    try expectFault(.{ .kind = .ambiguous, .name = "glowcap_second" }, Single, .{ First, Second, Second });
    try std.testing.expectEqualStrings(
        "bindings/ffi_omissions/rust.zig: omission of `glowcap_removed` names no export in this generator's archives",
        comptime (Fault{ .kind = .unknown, .name = "glowcap_removed" }).message("bindings/ffi_omissions/rust.zig"),
    );
}
