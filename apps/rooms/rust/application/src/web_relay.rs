//! The Rooms web front's byte-forwarding request envelope. Both ends apply
//! these bounds before admitting a target or waiting for its host dial.
pub const MAX_TARGET_BYTES: usize = 2048;
pub const IROH_DIAL_TIMEOUT_MS: u32 = 30_000;
