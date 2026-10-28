//! A wire and a virtual answer may share a number and a resolver without
//! sharing a callback obligation. The answer name owns the distinction.
const std = @import("std");
const glowcap = @import("glowcap");
const model = glowcap.ocapn.model;
const session = glowcap.ocapn.session;

test "resolver links preserve wire and virtual answer namespaces" {
    var state = session.Session.initWith(std.testing.allocator, .{ .captp_version = .v1_0 });
    defer state.deinit();
    const wire = model.AnswerName.fromWire(.from(7));
    const virtual = model.AnswerName{ .virtual = .from(7) };
    try state.installInboundResolver(wire, .from(70));
    try state.installInboundResolver(virtual, .from(70));
    try std.testing.expectEqual(@as(usize, 2), state.v1_0_inbound_resolver_link.count());
    try std.testing.expectEqual(@as(?model.ImportPosition, .from(70)), state.resolverForInboundAnswer(wire));
    try std.testing.expectEqual(@as(?model.ImportPosition, .from(70)), state.resolverForInboundAnswer(virtual));
    try std.testing.expect(state.v1_0_inbound_resolver_link.remove(wire));
    try std.testing.expect(state.resolverForInboundAnswer(wire) == null);
    try std.testing.expectEqual(@as(?model.ImportPosition, .from(70)), state.resolverForInboundAnswer(virtual));
}
