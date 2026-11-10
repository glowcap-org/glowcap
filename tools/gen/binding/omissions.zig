//! Join binding-owned omissions to complete C symbol inventories before rendering.

const std = @import("std");

pub const ValidationError = error{
    MissingInventorySymbol,
    UnknownInventorySymbol,
    InvalidInventorySymbol,
    DuplicateInventorySymbol,
    UnknownOmission,
    AmbiguousOmission,
    DuplicateOmission,
    EmptyOmissionReason,
};

/// Check all archives before filtering, including rows the binding omits.
/// Policy names identify exports across this generator's complete archive set.
pub fn validate(comptime policy: type, comptime archives: anytype) ValidationError!void {
    @setEvalBranchQuota(2_000_000);
    inline for (archives) |Archive| {
        inline for (Archive.symbols.symbols, 0..) |row, i| {
            if (comptime @hasDecl(Archive, row.name)) {
                if (@typeInfo(@TypeOf(@field(Archive, row.name))) != .@"fn")
                    return error.InvalidInventorySymbol;
            } else return error.UnknownInventorySymbol;
            inline for (Archive.symbols.symbols, 0..) |other, j| {
                if (j < i and std.mem.eql(u8, row.name, other.name))
                    return error.DuplicateInventorySymbol;
            }
        }
        inline for (@typeInfo(Archive).@"struct".decl_names) |name| {
            if (comptime !std.mem.startsWith(u8, name, "glowcap_")) continue;
            if (comptime @typeInfo(@TypeOf(@field(Archive, name))) != .@"fn") continue;
            var found = false;
            inline for (Archive.symbols.symbols) |row| {
                if (std.mem.eql(u8, name, row.name)) found = true;
            }
            if (!found) return error.MissingInventorySymbol;
        }
    }
    inline for (policy.omissions, 0..) |entry, i| {
        if (std.mem.trim(u8, entry.reason, " \t\r\n").len == 0) return error.EmptyOmissionReason;
        inline for (policy.omissions, 0..) |other, j| {
            if (j < i and std.mem.eql(u8, entry.name, other.name)) return error.DuplicateOmission;
        }
        var matches: usize = 0;
        inline for (archives) |Archive| {
            inline for (Archive.symbols.symbols) |row| {
                if (std.mem.eql(u8, entry.name, row.name)) matches += 1;
            }
        }
        if (matches == 0) return error.UnknownOmission;
        if (matches != 1) return error.AmbiguousOmission;
    }
}

/// Keep the inventory's order, consulting the policy only for membership.
pub fn omits(comptime policy: type, comptime name: []const u8) bool {
    @setEvalBranchQuota(50_000);
    inline for (policy.omissions) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

const Row = struct { name: []const u8 };
const First = struct {
    pub const symbols = struct {
        pub const symbols = [_]Row{.{ .name = "glowcap_first" }};
    };
    pub fn glowcap_first() void {}
};
const Second = struct {
    pub const symbols = struct {
        pub const symbols = [_]Row{.{ .name = "glowcap_second" }};
    };
    pub fn glowcap_second() void {}
};
const EmptyPolicy = struct {
    pub const omissions = .{};
};

test "binding omissions join a complete archive set and retain explicit decisions" {
    const Policy = struct {
        pub const omissions = .{
            .{ .name = "glowcap_first", .reason = "provided by the binding" },
            .{ .name = "glowcap_second", .reason = "unused" },
        };
    };
    try validate(Policy, .{ First, Second });
    try std.testing.expect(omits(Policy, "glowcap_first"));
    try std.testing.expect(omits(Policy, "glowcap_second"));
    try std.testing.expect(!omits(Policy, "glowcap_third"));
    try std.testing.expect(!omits(EmptyPolicy, "glowcap_first"));
    try std.testing.expectError(error.UnknownOmission, validate(Policy, .{First}));
}

test "binding omissions refuse stale duplicate ambiguous and unexplained entries" {
    const Stale = struct {
        pub const omissions = .{.{ .name = "glowcap_removed", .reason = "unused" }};
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
    const Ambiguous = struct {
        pub const omissions = .{.{ .name = "glowcap_first", .reason = "unused" }};
    };
    try std.testing.expectError(error.UnknownOmission, validate(Stale, .{First}));
    try std.testing.expectError(error.DuplicateOmission, validate(Duplicate, .{First}));
    try std.testing.expectError(error.EmptyOmissionReason, validate(Blank, .{First}));
    try std.testing.expectError(error.EmptyOmissionReason, validate(Empty, .{First}));
    try std.testing.expectError(error.AmbiguousOmission, validate(Ambiguous, .{ First, First }));
}

test "binding inventory checks include omitted rows and every reflected export" {
    const Omitted = struct {
        pub const omissions = .{.{ .name = "glowcap_first", .reason = "unused" }};
    };
    const Missing = struct {
        pub const symbols = struct {
            pub const symbols = [_]Row{};
        };
        pub const glowcap_first = First.glowcap_first;
    };
    const Unknown = struct {
        pub const symbols = First.symbols;
    };
    const Invalid = struct {
        pub const symbols = First.symbols;
        pub const glowcap_first: u8 = 1;
    };
    const Duplicate = struct {
        pub const symbols = struct {
            pub const symbols = [_]Row{ .{ .name = "glowcap_first" }, .{ .name = "glowcap_first" } };
        };
        pub const glowcap_first = First.glowcap_first;
    };
    try std.testing.expectError(error.MissingInventorySymbol, validate(EmptyPolicy, .{Missing}));
    try std.testing.expectError(error.UnknownInventorySymbol, validate(Omitted, .{Unknown}));
    try std.testing.expectError(error.InvalidInventorySymbol, validate(Omitted, .{Invalid}));
    try std.testing.expectError(error.DuplicateInventorySymbol, validate(Omitted, .{Duplicate}));
}
