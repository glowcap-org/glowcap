//! Vendor-neutral carrier failure detail shared by TLS engines and carrier
//! failure projection. Zero/null means that the selected carrier cannot observe
//! the fact; adapters must not invent it.

pub const Detail = struct {
    verification_flags: u32 = 0,
    peer_alert: ?u8 = null,
    engine_code: ?i32 = null,
};
