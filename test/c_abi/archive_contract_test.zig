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
        pub const PANCAKE_MODE: u32 = 7;
        pub fn contractCall(value: u32) callconv(.c) u32 {
            return value;
        }
    };
    const Calls64 = struct {
        pub const symbols = Symbols;
        pub const PANCAKE_MODE: u32 = 7;
        pub fn contractCall(value: u64) callconv(.c) u64 {
            return value;
        }
    };
    const CallsDifferentConstant = struct {
        pub const PANCAKE_MODE: u32 = 8;
        pub const symbols = Symbols;
        pub fn contractCall(value: u32) callconv(.c) u32 {
            return value;
        }
    };
    const CallsReordered = struct {
        pub const PANCAKE_MODE: u32 = 7;
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
