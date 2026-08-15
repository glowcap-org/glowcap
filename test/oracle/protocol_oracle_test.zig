const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const protocol_oracle = @import("protocol_oracle.zig");

test "protocol oracle enumerates every shipped message arm" {
    // Truth derives from the `model.Message` union, reached through the
    // model's kind registry: a union arm with no oracle arm fails here, so
    // `zig build oracle-check` alone refuses new protocol vocabulary that
    // carries no oracle pressure.
    const fields = @typeInfo(model.Message).@"union".fields;
    try std.testing.expectEqual(fields.len, model.message_kinds.len);
    try std.testing.expectEqual(fields.len, protocol_oracle.message_arms.len);
    inline for (fields, 0..) |field, i| {
        if (comptime (i < model.message_kinds.len and i < protocol_oracle.message_arms.len)) {
            try std.testing.expectEqualStrings(field.name, model.message_kinds[i].tag_name);
            try std.testing.expectEqualStrings(model.message_kinds[i].model_name, protocol_oracle.message_arms[i].name);
        }
    }
}

test "protocol oracle exposes the checked-in Syrup fixture corpus" {
    // Corpus/registry agreement — every `.bin` on disk registered, every
    // registered name on disk — is held both ways by source-check's
    // checkOracleCorpusRegistry. This proves the embedded bytes are
    // reachable by name and non-empty.
    const abort = protocol_oracle.fixtureByName("op_abort.bin").?;
    try std.testing.expectEqualStrings("op_abort.bin", abort.name);
    try std.testing.expect(abort.bytes().len > 0);

    const handoff = protocol_oracle.fixtureByName("desc_handoff_give_signed.bin").?;
    try std.testing.expect(handoff.bytes().len > 0);
}
