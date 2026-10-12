//! Stable return-code vocabulary shared by every Glowcap C archive.
//!
//! The generic code classifies a result for portable branching. Concrete
//! causes remain in the immediate last-error slot or a structured failure
//! report. This leaf only owns the stable numeric family and its validation.

const failure_diagnostics = @import("failure_diagnostics.zig");
const locator_adapter = @import("locator_adapter.zig");

pub const GLOWCAP_OK: i32 = 0;
pub const GLOWCAP_ERR_NULL_POINTER: i32 = -1;

/// A non-pointer argument was out of range or unparseable (e.g. a zero frame
/// cap, or a host string that is not an address). Distinct from `_NULL_POINTER`
/// (a required pointer was null) and `_IO` (the network itself failed).
pub const GLOWCAP_ERR_INVALID_ARGUMENT: i32 = -2;
pub const GLOWCAP_ERR_SESSION: i32 = -3;
pub const GLOWCAP_ERR_CODEC: i32 = -4;
pub const GLOWCAP_ERR_INTERNAL: i32 = -5;
pub const GLOWCAP_ERR_WOULD_BLOCK: i32 = -6;

/// Translate the shared locator adapter's complete error set at C crossings.
pub fn locatorAdapterErrorCode(err: locator_adapter.CloneViewError) i32 {
    return switch (err) {
        error.OutOfMemory => GLOWCAP_ERR_INTERNAL,
        error.InvalidLocatorView => GLOWCAP_ERR_INVALID_ARGUMENT,
    };
}

/// Project a dial's failure onto the C result an embedder can act on. One
/// table for every transport archive, so a retry policy written against
/// `GLOWCAP_ERR_TIMEOUT` or `GLOWCAP_ERR_WOULD_BLOCK` holds over each of them
/// alike. An archive names the concrete cause in its last-error text.
pub fn dialFailureCode(err: anyerror) i32 {
    return switch (err) {
        error.InvalidAddress, error.InvalidOptions => GLOWCAP_ERR_INVALID_ARGUMENT,
        error.TimedOut => GLOWCAP_ERR_TIMEOUT,
        error.WouldBlock => GLOWCAP_ERR_WOULD_BLOCK,
        error.OutOfMemory => GLOWCAP_ERR_INTERNAL,
        else => GLOWCAP_ERR_IO,
    };
}

/// The peer closed the stream gracefully on a frame boundary (clean EOF).
pub const GLOWCAP_ERR_CLOSED: i32 = -7;
/// An underlying socket read/write failed. The archive's last-error surface
/// carries the concrete cause.
pub const GLOWCAP_ERR_IO: i32 = -8;
/// Inbound bytes were not a structurally valid frame.
pub const GLOWCAP_ERR_MALFORMED: i32 = -9;
/// An inbound frame exceeded the endpoint's `max_frame_bytes`.
pub const GLOWCAP_ERR_FRAME_TOO_LARGE: i32 = -10;
/// A value sent across the typed surface uses a variant the C ABI cannot carry.
pub const GLOWCAP_ERR_UNSUPPORTED_VALUE: i32 = -11;
/// A promise the partner broke, distinct from a local or transport failure.
pub const GLOWCAP_ERR_BROKEN: i32 = -12;
/// A well-formed lookup found nothing.
pub const GLOWCAP_ERR_NOT_FOUND: i32 = -13;
/// A caller-provided output buffer was too small. The call reports the required
/// length so the caller can retry.
pub const GLOWCAP_ERR_BUFFER_TOO_SMALL: i32 = -14;
/// A caller-set deadline elapsed without a wire or session failure.
pub const GLOWCAP_ERR_TIMEOUT: i32 = -15;

comptime {
    const errors = [_]i32{
        GLOWCAP_ERR_NULL_POINTER,
        GLOWCAP_ERR_INVALID_ARGUMENT,
        GLOWCAP_ERR_SESSION,
        GLOWCAP_ERR_CODEC,
        GLOWCAP_ERR_INTERNAL,
        GLOWCAP_ERR_WOULD_BLOCK,
        GLOWCAP_ERR_CLOSED,
        GLOWCAP_ERR_IO,
        GLOWCAP_ERR_MALFORMED,
        GLOWCAP_ERR_FRAME_TOO_LARGE,
        GLOWCAP_ERR_UNSUPPORTED_VALUE,
        GLOWCAP_ERR_BROKEN,
        GLOWCAP_ERR_NOT_FOUND,
        GLOWCAP_ERR_BUFFER_TOO_SMALL,
        GLOWCAP_ERR_TIMEOUT,
    };
    for (errors, 1..) |code, ordinal| {
        if (code != -@as(i32, @intCast(ordinal)))
            @compileError("prerelease C error codes must remain contiguous");
    }
}

/// Whether `value` is absent (`0`) or one of the stable public result codes.
/// The contiguity assertion above makes the range itself the one authority.
pub fn isStableFailureResult(value: i32) bool {
    return value == GLOWCAP_OK or
        (value <= GLOWCAP_ERR_NULL_POINTER and value >= GLOWCAP_ERR_TIMEOUT);
}

/// Validate the typed-cause portion of a structured failure report. A report
/// with consequences names the first one. A report without consequences must
/// not carry secondary fields that contradict its count.
pub fn hasValidFailureCauses(report: failure_diagnostics.GlowcapFailureReport) bool {
    if (!isStableFailureResult(report.primary_result) or
        (report.primary_result == GLOWCAP_OK and report.primary_name_len == 0)) return false;
    if (report.secondary_count == 0) {
        return report.secondary_result == GLOWCAP_OK and
            report.secondary_name_len == 0 and
            report.secondary_message_len == 0;
    }
    return isStableFailureResult(report.secondary_result) and report.secondary_name_len != 0;
}
