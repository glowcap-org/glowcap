const std = @import("std");
const shared = @import("c_abi_shared");

test "archive fingerprints separate archive families" {
    const Archive = struct {
        pub const symbols = struct {
            pub const symbols = [_]shared.symbols.Symbol{.{ .name = "contractCall" }};
        };

        pub fn contractCall() callconv(.c) void {}
    };
    const layouts = [_]shared.archive_contract.Layout{};

    const archive_a = comptime shared.archive_contract.fingerprint("archive-a", Archive, .{layouts});
    const archive_b = comptime shared.archive_contract.fingerprint("archive-b", Archive, .{layouts});
    try std.testing.expect(archive_a != archive_b);
}

test "archive fingerprints follow reflected signatures, constants, and layouts" {
    const Symbols = struct {
        pub const symbols = [_]shared.symbols.Symbol{.{ .name = "contractCall" }};
    };
    const Layout32 = extern struct { value: u32 };
    const Layout64 = extern struct { value: u64 };
    const Calls32 = struct {
        pub const symbols = Symbols;
        pub const GLOWCAP_MODE: u32 = 7;
        pub fn contractCall(value: u32) callconv(.c) u32 {
            return value;
        }
    };
    const Calls64 = struct {
        pub const symbols = Symbols;
        pub const GLOWCAP_MODE: u32 = 7;
        pub fn contractCall(value: u64) callconv(.c) u64 {
            return value;
        }
    };
    const CallsDifferentConstant = struct {
        pub const GLOWCAP_MODE: u32 = 8;
        pub const symbols = Symbols;
        pub fn contractCall(value: u32) callconv(.c) u32 {
            return value;
        }
    };
    const CallsReordered = struct {
        pub const GLOWCAP_MODE: u32 = 7;
        pub const symbols = Symbols;
        pub fn contractCall(value: u32) callconv(.c) u32 {
            return value;
        }
    };
    const layouts32 = [_]shared.archive_contract.Layout{
        shared.archive_contract.layout("ROW", Layout32),
    };
    const layouts64 = [_]shared.archive_contract.Layout{
        shared.archive_contract.layout("ROW", Layout64),
    };
    const baseline = comptime shared.archive_contract.fingerprint("test", Calls32, .{layouts32});
    const signature_changed = comptime shared.archive_contract.fingerprint("test", Calls64, .{layouts32});
    const constant_changed = comptime shared.archive_contract.fingerprint("test", CallsDifferentConstant, .{layouts32});
    const layout_changed = comptime shared.archive_contract.fingerprint("test", Calls32, .{layouts64});
    const declarations_reordered = comptime shared.archive_contract.fingerprint("test", CallsReordered, .{layouts32});
    const repeated = comptime shared.archive_contract.fingerprint("test", Calls32, .{layouts32});

    try std.testing.expect(baseline != signature_changed);
    try std.testing.expect(baseline != constant_changed);
    try std.testing.expect(baseline != layout_changed);
    try std.testing.expectEqual(baseline, declarations_reordered);
    try std.testing.expectEqual(baseline, repeated);
}

test "archive fingerprints follow C crossing annotations" {
    const Fixture = struct {
        fn archive(comptime symbol: shared.symbols.Symbol) type {
            return struct {
                pub const symbols = struct {
                    pub const symbols = [_]shared.symbols.Symbol{symbol};
                };
                pub fn contractCall(_: *u8) callconv(.c) void {}
            };
        }
    };
    const layouts = [_]shared.archive_contract.Layout{};
    const baseline = comptime shared.archive_contract.fingerprint("test", Fixture.archive(.{ .name = "contractCall" }), .{layouts});
    inline for ([_]shared.symbols.Symbol{
        .{ .name = "contractCall", .out_params = &.{0} },
        .{ .name = "contractCall", .pointer_params = &.{0} },
        .{ .name = "contractCall", .blocking = true },
        .{ .name = "contractCall", .nonblocking = true },
    }) |symbol| {
        const changed = comptime shared.archive_contract.fingerprint("test", Fixture.archive(symbol), .{layouts});
        try std.testing.expect(baseline != changed);
    }
}

test "archive fingerprint names keep a type's shape and cut its module path" {
    const unqualified = shared.archive_contract.unqualified;
    try std.testing.expectEqualStrings("*Store", comptime unqualified("*c_abi.loam.layouts.Store"));
    try std.testing.expectEqualStrings("?*const fn (*B, u32) callconv(.c) D", comptime unqualified("?*const fn (*a.B, u32) callconv(.c) a.c.D"));
    try std.testing.expectEqualStrings("Aligned(u8,null)", comptime unqualified("array_list.Aligned(u8,null)"));
    try std.testing.expectEqualStrings("[4]B", comptime unqualified("[4]a.B"));
    try std.testing.expectEqualStrings("error{X}!B", comptime unqualified("error{X}!a.B"));
    try std.testing.expectEqualStrings("[*:0]const u8", comptime unqualified("[*:0]const u8"));
    try std.testing.expectEqualStrings("1.5", comptime unqualified("1.5"));
    try std.testing.expectEqualStrings("a test name sits Row", comptime unqualified("a test name sits in.Row"));
}

test "archive fingerprints ignore the Zig namespace a declaration sits in" {
    const First = struct {
        pub const Row = extern struct { count: u32 };
        pub const symbols = struct {
            pub const symbols = [_]shared.symbols.Symbol{.{ .name = "contractCall" }};
        };

        pub fn contractCall(row: *const Row) callconv(.c) u32 {
            return row.count;
        }
    };
    const Second = struct {
        pub const Row = extern struct { count: u32 };
        pub const symbols = struct {
            pub const symbols = [_]shared.symbols.Symbol{.{ .name = "contractCall" }};
        };

        pub fn contractCall(row: *const Row) callconv(.c) u32 {
            return row.count;
        }
    };
    const Renamed = struct {
        pub const Other = extern struct { count: u32 };
        pub const symbols = struct {
            pub const symbols = [_]shared.symbols.Symbol{.{ .name = "contractCall" }};
        };

        pub fn contractCall(row: *const Other) callconv(.c) u32 {
            return row.count;
        }
    };
    const first_layouts = [_]shared.archive_contract.Layout{shared.archive_contract.layout("ROW", First.Row)};
    const second_layouts = [_]shared.archive_contract.Layout{shared.archive_contract.layout("ROW", Second.Row)};
    const renamed_layouts = [_]shared.archive_contract.Layout{shared.archive_contract.layout("ROW", Renamed.Other)};
    const first = comptime shared.archive_contract.fingerprint("archive", First, .{first_layouts});
    const second = comptime shared.archive_contract.fingerprint("archive", Second, .{second_layouts});
    const renamed = comptime shared.archive_contract.fingerprint("archive", Renamed, .{renamed_layouts});
    try std.testing.expectEqual(first, second);
    try std.testing.expect(first != renamed);
}

test "archive inventories match their exports one to one and name the offending symbol" {
    const Symbol = shared.symbols.Symbol;
    const contract = shared.archive_contract;
    const Complete = struct {
        pub const symbols = struct {
            pub const symbols = [_]Symbol{.{ .name = "glowcap_first" }};
        };
        pub fn glowcap_first() callconv(.c) void {}
        pub const glowcap_value: u8 = 1;
    };
    const Missing = struct {
        pub const symbols = struct {
            pub const symbols = [_]Symbol{};
        };
        pub const glowcap_first = Complete.glowcap_first;
    };
    const Duplicate = struct {
        pub const symbols = struct {
            pub const symbols = [_]Symbol{ .{ .name = "glowcap_first" }, .{ .name = "glowcap_first" } };
        };
        pub const glowcap_first = Complete.glowcap_first;
    };
    const Unknown = struct {
        pub const symbols = Complete.symbols;
    };
    const NotFunction = struct {
        pub const symbols = Complete.symbols;
        pub const glowcap_first: u8 = 1;
    };
    try std.testing.expect(comptime contract.inventoryFault(Complete) == null);
    inline for (.{
        .{ Missing, contract.InventoryFault.Kind.missing_row },
        .{ Duplicate, contract.InventoryFault.Kind.duplicate_row },
        .{ Unknown, contract.InventoryFault.Kind.unknown_export },
        .{ NotFunction, contract.InventoryFault.Kind.not_function },
    }) |case| {
        const broken = comptime contract.inventoryFault(case[0]) orelse return error.TestExpectedFault;
        try std.testing.expectEqual(case[1], broken.kind);
        try std.testing.expectEqualStrings("glowcap_first", broken.name);
    }
    try std.testing.expectEqualStrings(
        "host archive: `glowcap_first` is an export with no row in its symbols.zig inventory",
        comptime (contract.InventoryFault{ .kind = .missing_row, .name = "glowcap_first" }).message("host"),
    );
}
