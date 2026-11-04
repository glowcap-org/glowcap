//! Profiles declare build requirements, independently of which method is emitted.
const std = @import("std");
const description = @import("description.zig");
const Model = @import("model.zig").Model;
const calls = @import("calls.zig");
const rust = @import("callbacks.zig");
const ts = @import("typescript.zig");

const ordinary_profiles = "{14\"glowcap.values1+}";
const receipt_profiles = "{12\"loam.receipt1+14\"glowcap.values1+}";
const ordinary = "{1\"R<9'interface{1\"m<6'method[]6'string4'call>}>}";
const receipt = "{1\"R<9'interface{1\"m<6'method[<9'parameter1\"p<7'promise5'value>f>]9'undefined12'loam.receipt>}>}";

fn checked(a: std.mem.Allocator, profiles: []const u8, definitions: []const u8) !Model {
    const bytes = try std.fmt.allocPrint(a, "<17'glowcap:interface1+{s}{s}>", .{ profiles, definitions });
    return Model.init(a, try description.read(a, bytes));
}

test "ordinary descriptions emit without declaring the receipt convention" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ ordinary_profiles, receipt_profiles }) |profiles| {
        var model = try checked(a, profiles, ordinary);
        const methods = [_]calls.Named{.{ .api = "read", .call = try calls.read(&model, "R", "m") }};
        const rust_code = try rust.emit(a, &methods, &.{});
        const ts_code = try ts.emit(a, &methods);
        try std.testing.expect(std.mem.indexOf(u8, rust_code, " as read;") != null);
        try std.testing.expect(std.mem.indexOf(u8, rust_code, "Pending<String>") != null);
        try std.testing.expect(std.mem.indexOf(u8, rust_code, "PreparedMutation") == null);
        try std.testing.expect(std.mem.indexOf(u8, ts_code, "Pending<string>") != null);
    }
}

test "receipt methods require their declared convention before emission" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.InvalidDescription, checked(a, ordinary_profiles, receipt));
    var model = try checked(a, receipt_profiles, receipt);
    const methods = [_]calls.Named{.{ .api = "prepare_read", .call = try calls.read(&model, "R", "m") }};
    const code = try rust.emit(a, &methods, &.{});
    try std.testing.expect(std.mem.indexOf(u8, code, " as prepare_read;") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "PreparedMutation<()>") != null);
    // A selected ordinary method cannot hide a receipt elsewhere in the bundle.
    const mixed = "{1\"R<9'interface{1\"a<6'method[]6'string4'call>1\"b<6'method[]9'undefined12'loam.receipt>}>}";
    try std.testing.expectError(error.InvalidDescription, checked(a, ordinary_profiles, mixed));
}

test "declared unsupported profiles remain errors even without receipt use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "{}",
        "{12\"loam.receipt1+}",
        "{14\"glowcap.values2+}",
        "{12\"loam.receipt2+14\"glowcap.values1+}",
        "{13\"other.profile1+14\"glowcap.values1+}",
        "{14\"glowcap.valuest}",
        "{14\"glowcap.values1+f1+}",
    }) |profiles| try std.testing.expectError(error.InvalidDescription, checked(a, profiles, ordinary));
    const unknown = "{1\"R<9'interface{1\"m<6'method[]9'undefined7'unknown>}>}";
    try std.testing.expectError(error.InvalidDescription, checked(a, receipt_profiles, unknown));
}
