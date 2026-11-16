//! The `GLOWCAP_*` integer constants `glowcap_host.h` leaves out, with the
//! reason. `host.zig` holds the header against them, and `driver.zig` reads the
//! same rows so a driver re-export never carries a constant the host header
//! does not own.

const header_emit = @import("header_emit.zig");

const binding_default = "A default the language bindings share through their generated constants. No C function takes or documents it, and a C embedder sets its own bound.";
pub const omitted = [_]header_emit.ConstOmission{
    header_emit.fingerprintOmission("GLOWCAP_HOST_ARCHIVE_FINGERPRINT", "glowcap_host_archive_fingerprint"),
    .{ .name = "GLOWCAP_HANDSHAKE_TIMEOUT_MS", .reason = "Binding policy: how long a binding's establish waits for a partner's op:start-session. " ++ binding_default },
    .{ .name = "GLOWCAP_DEFAULT_PENDING_ACCEPTS", .reason = "Binding policy: accepted connections a high-level binding listener holds. " ++ binding_default },
    .{ .name = "GLOWCAP_DEFAULT_HANDSHAKE_CONCURRENCY", .reason = "Binding policy: handshakes one high-level binding listener drives at once. " ++ binding_default },
    .{ .name = "GLOWCAP_MAX_HANDSHAKE_CONCURRENCY", .reason = "Binding policy: the most handshakes one high-level binding listener drives at once. " ++ binding_default },
};
