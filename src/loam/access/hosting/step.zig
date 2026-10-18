//! The step a request owner returns while its hosted call prepares.
const loam = @import("loam_core");

/// The preparation's step, plus `.more`: drain the call's operations and
/// call again.
pub const Step = union(enum) { ready, read: loam.Read, waiting, more };
