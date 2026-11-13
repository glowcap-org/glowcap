//! CapTP rail flash after a verb settles (shared paint + await/exec).
const std = @import("std");

pub const Flash = enum { none, exports, imports, answers };

/// The flash a paint shows. Reduced motion shows none.
pub fn shown(flash: Flash, reduced_motion: bool) Flash {
    return if (reduced_motion) .none else flash;
}

pub fn flashForVerb(verb: []const u8) Flash {
    if (std.mem.eql(u8, verb, "publish")) return .exports;
    if (std.mem.eql(u8, verb, "fetch")) return .imports;
    if (std.mem.eql(u8, verb, "call") or std.mem.eql(u8, verb, "tell")) return .answers;
    return .none;
}
