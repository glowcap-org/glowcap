//! Resource structure, managed grants, and durable owner storage for applications.
//! Core, codecs, and storage participants perform no I/O. Loam owns shared
//! transactions and residency; managed capability hosting remains planned.

pub const core = @import("loam_access_core");
pub const records = @import("loam_access_records");
pub const storage = @import("loam_access_storage");
pub const hosting = @import("loam_access_hosting");
