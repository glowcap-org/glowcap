//! Bounds shared by every target in this fuzz suite.

/// Upper bound on one fuzz input, matching the sibling targets.
pub const max_input = 4096;

/// Frames past this are refused rather than decoded. It is what bounds how far
/// the spill can grow.
pub const frame_cap = 1024;
