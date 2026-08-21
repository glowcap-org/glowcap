//! Export/answer pairing for a Host-local promise projected onto one session.
//!
//! The export is the partner-visible promise reference; the virtual inbound
//! answer is its settlement and pipelining cell. Their explicit BiMap link is
//! the authority because CapTP allocates those namespaces independently.

const std = @import("std");
const model = @import("model");
const answers = @import("answers/store.zig");

pub const Projection = struct {
    export_position: model.ExportPosition,
    answer_name: model.AnswerName,
    answer_target: answers.AnswerTarget,
};

pub fn allocate(self: anytype) !Projection {
    const export_position = try self.allocatePromiseExport();
    errdefer self.releaseUnsharedExport(export_position);
    const answer_name = model.AnswerName.fromVirtual(try self.allocateInboundAnswer());
    try self.installInboundAnswerNamed(answer_name);
    errdefer self.abandonUnsharedInboundAnswerNamed(answer_name);
    try self.outbound_resolver_link.put(self.allocator, export_position, .{
        .local_promise_answer = answer_name,
    });
    return .{
        .export_position = export_position,
        .answer_name = answer_name,
        .answer_target = self.answerTargetNamed(answer_name).?,
    };
}

pub fn answerForExport(self: anytype, export_position: model.ExportPosition) ?model.AnswerName {
    const purpose = self.outbound_resolver_link.getByKey(export_position) orelse return null;
    return switch (purpose) {
        .local_promise_answer => |answer| answer,
        else => null,
    };
}

pub fn isAnswer(self: anytype, answer_name: model.AnswerName) bool {
    return self.outbound_resolver_link.getByValue(.{
        .local_promise_answer = answer_name,
    }) != null;
}

pub fn abandon(self: anytype, export_position: model.ExportPosition) void {
    const answer_name = answerForExport(self, export_position) orelse unreachable;
    std.debug.assert(self.outbound_resolver_link.removeByKey(export_position));
    self.abandonUnsharedInboundAnswerNamed(answer_name);
    self.releaseUnsharedExport(export_position);
}

pub fn retireReleased(self: anytype, answer_name: model.AnswerName) void {
    const export_position = self.outbound_resolver_link.getByValue(.{
        .local_promise_answer = answer_name,
    }) orelse return;
    if (self.exports.wireHeld(export_position) != 0 or !self.answerResolvedNamed(answer_name)) return;
    std.debug.assert(self.outbound_resolver_link.removeByKey(export_position));
    self.releaseUnsharedExport(export_position);
    const entry = self.inbound_answers.getPtr(answer_name) orelse unreachable;
    self.releaseInboundAnswerCell(entry);
    self.inbound_answers.remove(answer_name);
}
