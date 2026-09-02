//! Exit codes for the glowcap CLI (ADR-0084 operability).
pub const ok: u8 = 0;
pub const internal: u8 = 1;
pub const usage: u8 = 2;
pub const identity: u8 = 3;
pub const dial: u8 = 4;
pub const protocol_abort: u8 = 5;
/// Handshake or settle budget fired (ADR-0081). Never leave CapTP waits unbounded.
pub const timeout: u8 = 6;
/// State-dir single-writer lock held by another process.
pub const busy: u8 = 7;
