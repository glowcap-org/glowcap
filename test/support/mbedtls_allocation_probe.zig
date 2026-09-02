//! Test-only view of the private Mbed TLS allocation-accounting build.

const c = @import("allocation_probe_c");

pub const Snapshot = struct {
    current_bytes: usize,
    peak_bytes: usize,
    allocation_count: usize,
};

pub fn resetWindow() void {
    c.glowcap_mbedtls_probe_reset_window();
}

pub fn snapshot() Snapshot {
    return .{
        .current_bytes = c.glowcap_mbedtls_probe_current_bytes(),
        .peak_bytes = c.glowcap_mbedtls_probe_peak_bytes(),
        .allocation_count = c.glowcap_mbedtls_probe_allocation_count(),
    };
}
