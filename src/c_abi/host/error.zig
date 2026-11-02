//! Mechanical projection of driver-core Host failure categories into the C
//! result vocabulary, and of an error into a return code with its name recorded
//! for `glowcap_host_last_error`. Domain classification remains in
//! `driver_core`.

const driver_core = @import("driver_core");
const shared = @import("c_abi_shared");

pub fn code(kind: driver_core.HostFailure.Kind) i32 {
    return switch (kind) {
        .invalid_argument => shared.GLOWCAP_ERR_INVALID_ARGUMENT,
        .not_found => shared.GLOWCAP_ERR_NOT_FOUND,
        .would_block => shared.GLOWCAP_ERR_WOULD_BLOCK,
        .closed => shared.GLOWCAP_ERR_CLOSED,
        .session => shared.GLOWCAP_ERR_SESSION,
        .codec => shared.GLOWCAP_ERR_CODEC,
        .frame_too_large => shared.GLOWCAP_ERR_FRAME_TOO_LARGE,
        .internal => shared.GLOWCAP_ERR_INTERNAL,
    };
}

pub fn fromError(cause: anyerror) i32 {
    return code(driver_core.HostFailure.classify(cause));
}

/// Map a host-tier error to a C return code, recording the name for
/// `glowcap_host_last_error`.
pub fn errToCode(err: anyerror) i32 {
    // The marshal leaf raises `InvalidArgument` only after writing a message
    // naming the value it refused (`shared.refKindFromC`), which is the whole
    // diagnostic; stamping the bare error name over it would throw that away.
    // Every other error names itself and nothing more.
    if (err != error.InvalidArgument) shared.setLastError("host: {s}", .{@errorName(err)});
    return switch (err) {
        // These are C marshalling failures, not Host-domain failures.
        error.UnsupportedValue => shared.GLOWCAP_ERR_UNSUPPORTED_VALUE,
        error.NullPointer => shared.GLOWCAP_ERR_NULL_POINTER,
        else => fromError(err),
    };
}
