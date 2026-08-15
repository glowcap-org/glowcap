//! Mechanical projection of driver-core Host failure categories into the C
//! result vocabulary. Domain classification remains in `driver_core`.

const driver_core = @import("driver_core");
const shared = @import("c_abi_shared");

pub fn code(kind: driver_core.HostFailure.Kind) i32 {
    return switch (kind) {
        .invalid_argument => shared.PANCAKE_ERR_INVALID_ARGUMENT,
        .not_found => shared.PANCAKE_ERR_NOT_FOUND,
        .would_block => shared.PANCAKE_ERR_WOULD_BLOCK,
        .closed => shared.PANCAKE_ERR_CLOSED,
        .session => shared.PANCAKE_ERR_SESSION,
        .codec => shared.PANCAKE_ERR_CODEC,
        .frame_too_large => shared.PANCAKE_ERR_FRAME_TOO_LARGE,
        .internal => shared.PANCAKE_ERR_INTERNAL,
    };
}

pub fn fromError(cause: anyerror) i32 {
    return code(driver_core.HostFailure.classify(cause));
}
