//! Bounds every owner shares, so a stored configuration and a resident
//! structure refuse the same depth.

/// The deepest resource containment or grant delegation an owner may allow.
pub const max_depth = 64;
