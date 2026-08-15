//! Mechanical projection of native driver failure categories into the C result
//! vocabulary. Domain classification remains in `driver`.

const driver = @import("driver");
const shared = @import("c_abi_shared");

pub fn code(kind: driver.OperationFailure.Kind) i32 {
    return switch (kind) {
        .invalid_argument => shared.PANCAKE_ERR_INVALID_ARGUMENT,
        .would_block => shared.PANCAKE_ERR_WOULD_BLOCK,
        .timeout => shared.PANCAKE_ERR_TIMEOUT,
        .closed => shared.PANCAKE_ERR_CLOSED,
        .session => shared.PANCAKE_ERR_SESSION,
        .malformed => shared.PANCAKE_ERR_MALFORMED,
        .frame_too_large => shared.PANCAKE_ERR_FRAME_TOO_LARGE,
        .internal => shared.PANCAKE_ERR_INTERNAL,
        .io => shared.PANCAKE_ERR_IO,
    };
}

pub fn fromError(cause: anyerror) i32 {
    return code(driver.OperationFailure.classify(cause));
}
