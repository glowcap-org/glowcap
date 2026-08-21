//! Stable return-code vocabulary shared by every Pancake C archive.
//!
//! The generic code classifies a result for portable branching. Concrete
//! causes remain in the immediate last-error slot or a structured failure
//! report; this leaf only owns the stable numeric family and its validation.

const failure_diagnostics = @import("failure_diagnostics.zig");
const locator_adapter = @import("locator_adapter.zig");

pub const PANCAKE_OK: i32 = 0;
pub const PANCAKE_ERR_NULL_POINTER: i32 = -1;

/// A non-pointer argument was out of range or unparseable (e.g. a zero frame
/// cap, or a host string that is not an address). Distinct from `_NULL_POINTER`
/// (a required pointer was null) and `_IO` (the network itself failed).
pub const PANCAKE_ERR_INVALID_ARGUMENT: i32 = -2;
pub const PANCAKE_ERR_SESSION: i32 = -3;
pub const PANCAKE_ERR_CODEC: i32 = -4;
pub const PANCAKE_ERR_INTERNAL: i32 = -5;
pub const PANCAKE_ERR_WOULD_BLOCK: i32 = -6;

/// Translate the shared locator adapter's complete error set at C crossings.
pub fn locatorAdapterErrorCode(err: locator_adapter.CloneViewError) i32 {
    return switch (err) {
        error.OutOfMemory => PANCAKE_ERR_INTERNAL,
        error.InvalidLocatorView => PANCAKE_ERR_INVALID_ARGUMENT,
    };
}

/// The peer closed the stream gracefully on a frame boundary (clean EOF).
pub const PANCAKE_ERR_CLOSED: i32 = -7;
/// An underlying socket read/write failed; the archive's last-error surface
/// carries the concrete cause.
pub const PANCAKE_ERR_IO: i32 = -8;
/// Inbound bytes were not a structurally valid frame.
pub const PANCAKE_ERR_MALFORMED: i32 = -9;
/// An inbound frame exceeded the endpoint's `max_frame_bytes`.
pub const PANCAKE_ERR_FRAME_TOO_LARGE: i32 = -10;
/// A value sent across the typed surface uses a variant the C ABI cannot carry.
pub const PANCAKE_ERR_UNSUPPORTED_VALUE: i32 = -11;
/// A promise the partner broke, distinct from a local or transport failure.
pub const PANCAKE_ERR_BROKEN: i32 = -12;
/// A well-formed lookup found nothing.
pub const PANCAKE_ERR_NOT_FOUND: i32 = -13;
/// A caller-provided output buffer was too small; the call reports the required
/// length so the caller can retry.
pub const PANCAKE_ERR_BUFFER_TOO_SMALL: i32 = -14;
/// A caller-set deadline elapsed without a wire or session failure.
pub const PANCAKE_ERR_TIMEOUT: i32 = -15;

comptime {
    const errors = [_]i32{
        PANCAKE_ERR_NULL_POINTER,
        PANCAKE_ERR_INVALID_ARGUMENT,
        PANCAKE_ERR_SESSION,
        PANCAKE_ERR_CODEC,
        PANCAKE_ERR_INTERNAL,
        PANCAKE_ERR_WOULD_BLOCK,
        PANCAKE_ERR_CLOSED,
        PANCAKE_ERR_IO,
        PANCAKE_ERR_MALFORMED,
        PANCAKE_ERR_FRAME_TOO_LARGE,
        PANCAKE_ERR_UNSUPPORTED_VALUE,
        PANCAKE_ERR_BROKEN,
        PANCAKE_ERR_NOT_FOUND,
        PANCAKE_ERR_BUFFER_TOO_SMALL,
        PANCAKE_ERR_TIMEOUT,
    };
    for (errors, 1..) |code, ordinal| {
        if (code != -@as(i32, @intCast(ordinal)))
            @compileError("prerelease C error codes must remain contiguous");
    }
}

/// Whether `value` is absent (`0`) or one of the stable public result codes.
/// The contiguity assertion above makes the range itself the one authority.
pub fn isStableFailureResult(value: i32) bool {
    return value == PANCAKE_OK or
        (value <= PANCAKE_ERR_NULL_POINTER and value >= PANCAKE_ERR_TIMEOUT);
}

/// Validate the typed-cause portion of a structured failure report. A report
/// with consequences names the first one; a report without consequences must
/// not carry secondary fields that contradict its count.
pub fn hasValidFailureCauses(report: failure_diagnostics.PancakeFailureReport) bool {
    if (!isStableFailureResult(report.primary_result) or
        (report.primary_result == PANCAKE_OK and report.primary_name_len == 0)) return false;
    if (report.secondary_count == 0) {
        return report.secondary_result == PANCAKE_OK and
            report.secondary_name_len == 0 and
            report.secondary_message_len == 0;
    }
    return isStableFailureResult(report.secondary_result) and report.secondary_name_len != 0;
}
