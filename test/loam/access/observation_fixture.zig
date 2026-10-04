//! Copied wire replies keep observer authority and cursors beyond callback borrows.
const std = @import("std");
pub const d = @import("description_fixture.zig");
const h = d.h;
const model = d.f.model;

pub const Fronts = struct {
    receiver: model.Reference,
    canceller: model.Reference,
    pub fn from(value: model.Argument) !Fronts {
        if (value != .list or value.list.len != 2 or value.list[0] != .reference or value.list[1] != .reference) return error.InvalidObservationReply;
        return .{ .receiver = value.list[0].reference, .canceller = value.list[1].reference };
    }
};
pub fn cursor(value: model.Argument) !h.c.storage.Observation.Cursor {
    if (value != .tagged or !std.mem.eql(u8, value.tagged.tag, "access:observation") or value.tagged.value.len != 5) return error.InvalidObservationReply;
    const bytes = value.tagged.value[0];
    if (bytes != .bytes or bytes.bytes.len != @sizeOf(h.c.storage.Observation.Cursor)) return error.InvalidObservationReply;
    return bytes.bytes[0..@sizeOf(h.c.storage.Observation.Cursor)].*;
}
