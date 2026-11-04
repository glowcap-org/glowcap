//! Zig argument projection for the public creation request. Loam still owns
//! creation and its public capability reply.
const std = @import("std");
const model = @import("model.zig");
const Creation = model.Creation;
const literal = @import("literal.zig").write;

pub fn emit(a: std.mem.Allocator, method: Creation) ![]u8 {
    if (!std.mem.eql(u8, method.wire_name, model.creation_method)) return error.UnsupportedProjection;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "//! Generated from checked interface descriptions.\nconst std = @import(\"std\");\npub const add_verb = ");
    try literal(&out, a, method.wire_name);
    try out.print(a, ";\npub const min_text_bytes: usize = {d};\npub const max_text_bytes: usize = {d};\n", .{ method.minimum, method.maximum });
    try out.appendSlice(a,
        \\/// Borrowed through the hosting turn. The caller owns mutation and storage.
        \\pub fn addArguments(args: anytype) error{InvalidArguments}![]const u8 {
        \\    if (args.len != 1 or args[0] != .string) return error.InvalidArguments;
        \\    const text = args[0].string;
        \\    if (text.len < min_text_bytes or text.len > max_text_bytes or !std.unicode.utf8ValidateSlice(text)) return error.InvalidArguments;
        \\    return text;
        \\}
        \\
    );
    return out.toOwnedSlice(a);
}

/// Narrow direct receiver proof: two passable values and an undefined result.
/// The generated wrapper lends views only through the handler call.
pub fn emitDirect(a: std.mem.Allocator, call: @import("calls.zig").Call) ![]u8 {
    if (call.wire_name != null or call.effect != .call or call.required_parameters != 2 or
        call.parameters.len != 2 or call.parameters[0] != .value or
        call.parameters[1] != .value or call.result != .nothing) return error.UnsupportedProjection;
    return a.dupe(u8,
        \\//! Generated from checked interface descriptions.
        \\const glowcap = @import("glowcap");
        \\const model = glowcap.ocapn.model;
        \\
        \\/// Values borrow this call. Keeping one requires existing ownership operations.
        \\pub fn receive(receiver: anytype, delivery: glowcap.actors.Delivery) !model.Argument {
        \\    const peeled = delivery.verb != null;
        \\    if (try delivery.args.len() != @as(usize, if (peeled) 1 else 2)) return error.InvalidArguments;
        \\    // Two fixed stack view slots. No payload is copied or retained here.
        \\    // value admits every passable category; projection must finish before invoke.
        \\    const raw = [2]model.view.Argument{
        \\        if (delivery.verb) |symbol| .{ .symbol = symbol } else try delivery.args.at(0),
        \\        try delivery.args.at(if (peeled) 0 else 1),
        \\    };
        \\    try receiver.invoke(raw[0], raw[1]);
        \\    return .{ .void = {} };
        \\}
        \\
    );
}
