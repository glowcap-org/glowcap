//! Ordinary call signatures for the factory/callback qualification corpus.
//! Resolving and validating the description stays with the shared model.
const std = @import("std");
const Model = @import("model.zig").Model;

pub const Type = @import("call_type.zig").Type;
pub const Kind = std.meta.Tag(Type);
pub const Effect = enum { call, tell, receipt };
pub const Named = struct { api: []const u8, call: Call };
pub const Call = struct {
    wire_name: ?[]const u8,
    parameters: []const Type,
    required_parameters: usize,
    result: Type,
    effect: Effect,
};

pub fn read(a: std.mem.Allocator, model: *Model, receiver: []const u8, method_name: ?[]const u8) !Call {
    const fields = try model.method(receiver, method_name);
    const effect: Effect = if (fields[2].is("call")) .call else if (fields[2].is("tell")) .tell else if (fields[2].is("loam.receipt")) .receipt else return error.UnsupportedProjection;
    const parameters = try a.alloc(Type, fields[0].children.len);
    errdefer a.free(parameters);
    var required_parameters = parameters.len;
    for (fields[0].children, parameters, 0..) |parameter, *kind, i| {
        const param = try parameter.fields("parameter", 3);
        if (param[2].boolean) required_parameters = @min(required_parameters, i);
        kind.* = try model.callType(param[1]);
    }
    return .{ .wire_name = method_name, .parameters = parameters, .required_parameters = required_parameters, .result = try model.callType(fields[1]), .effect = effect };
}
