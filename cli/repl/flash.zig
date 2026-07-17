//! CapTP rail flash after a verb settles (shared paint + await/exec).
const std = @import("std");

pub const Flash = enum { none, exports, imports, answers };

pub fn flashForVerb(verb: []const u8) Flash {
    if (std.mem.eql(u8, verb, "publish")) return .exports;
    if (std.mem.eql(u8, verb, "fetch")) return .imports;
    if (std.mem.eql(u8, verb, "call") or std.mem.eql(u8, verb, "tell")) return .answers;
    return .none;
}
