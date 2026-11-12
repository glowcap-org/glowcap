//! A provider's structured failure report decodes through one status table:
//! every stable code keeps the class the driver projects back to it, and a
//! code outside the vocabulary, primary or secondary, is a typed refusal.

const std = @import("std");
const c = @import("c_abi_shared");
const cdrv = @import("c_abi_driver");

const provider_failure = cdrv.white_box.provider_failure;

fn report(code: i32) c.GlowcapProviderFailure {
    var failure = c.transport_provider.emptyProviderFailure();
    failure.result = code;
    failure.primary_name = "ConnectionRefused";
    failure.primary_name_len = "ConnectionRefused".len;
    return failure;
}

test "every stable provider status decodes to the class its C projection names" {
    inline for (.{
        .{ c.GLOWCAP_ERR_NULL_POINTER, .invalid_argument },
        .{ c.GLOWCAP_ERR_INVALID_ARGUMENT, .invalid_argument },
        .{ c.GLOWCAP_ERR_NOT_FOUND, .not_found },
        .{ c.GLOWCAP_ERR_INTERNAL, .internal },
        .{ c.GLOWCAP_ERR_WOULD_BLOCK, .would_block },
        .{ c.GLOWCAP_ERR_CLOSED, .closed },
        .{ c.GLOWCAP_ERR_TIMEOUT, .timeout },
        .{ c.GLOWCAP_ERR_SESSION, .session },
        .{ c.GLOWCAP_ERR_MALFORMED, .malformed },
        .{ c.GLOWCAP_ERR_FRAME_TOO_LARGE, .frame_too_large },
        .{ c.GLOWCAP_ERR_IO, .io },
    }) |row| {
        const chain = try provider_failure.chain(row[0], report(row[0]));
        try std.testing.expectEqual(@as(@TypeOf(chain.classification.?), row[1]), chain.classification.?);
        try std.testing.expectEqualStrings("ConnectionRefused", chain.cause_name.?);
    }
}

test "a provider status outside the vocabulary is refused, primary or secondary" {
    const unknown: i32 = -9999;
    try std.testing.expectError(error.InvalidProviderFailure, provider_failure.chain(unknown, report(unknown)));

    var secondary = report(c.GLOWCAP_ERR_IO);
    secondary.secondary_result = unknown;
    secondary.secondary_name = "Mystery";
    secondary.secondary_name_len = "Mystery".len;
    secondary.secondary_count = 1;
    try std.testing.expectError(error.InvalidProviderFailure, provider_failure.chain(c.GLOWCAP_ERR_IO, secondary));

    secondary.secondary_result = c.GLOWCAP_ERR_TIMEOUT;
    const chain = try provider_failure.chain(c.GLOWCAP_ERR_IO, secondary);
    try std.testing.expectEqual(.timeout, chain.secondary_classification.?);
}
