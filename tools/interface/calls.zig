//! Ordinary call signatures for the factory/callback qualification corpus.
//! Resolving and validating the description stays with the shared model.
const std = @import("std");
const Model = @import("model.zig").Model;
const Node = @import("description.zig").Node;

pub const Kind = enum { text, target, pending_target, pending_value, nothing, value };
pub const Effect = enum { call, tell, receipt };
pub const Named = struct { api: []const u8, call: Call };
pub const Call = struct {
    wire_name: []const u8,
    parameters: []const Kind,
    result: Kind,
    effect: Effect,
};

pub fn read(a: std.mem.Allocator, model: *Model, receiver: []const u8, method_name: []const u8) !Call {
    const receiver_fields = try (try model.definitions.get(receiver)).fields("interface", 1);
    const fields = try (try receiver_fields[0].get(method_name)).fields("method", 3);
    const effect: Effect = if (fields[2].is("call")) .call else if (fields[2].is("tell")) .tell else if (fields[2].is("loam.receipt")) .receipt else return error.UnsupportedProjection;
    const parameters = try a.alloc(Kind, fields[0].children.len);
    errdefer a.free(parameters);
    for (fields[0].children, parameters) |parameter, *kind| {
        const param = try parameter.fields("parameter", 3);
        if (param[2].boolean) return error.UnsupportedProjection;
        kind.* = try classify(model, param[1]);
    }
    return .{ .wire_name = method_name, .parameters = parameters, .result = try classify(model, fields[1]), .effect = effect };
}

fn classify(model: *Model, input: Node) !Kind {
    const node = try model.resolve(input);
    if (node.is("string")) return .text;
    if (node.is("undefined")) return .nothing;
    if (node.is("value")) return .value;
    if (node.kind == .record) {
        if (std.mem.eql(u8, node.bytes, "interface")) return .target;
        if (std.mem.eql(u8, node.bytes, "promise")) {
            const fulfilled = try model.resolve((try node.fields("promise", 1))[0]);
            if (fulfilled.is("value")) return .pending_value;
            if (fulfilled.kind == .record and std.mem.eql(u8, fulfilled.bytes, "interface")) return .pending_target;
        }
    }
    return error.UnsupportedProjection;
}
