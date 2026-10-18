//! What a disk engine holds beyond its database: the store directory's owner
//! lock across processes, and the admission word across the threads of one
//! process. The volatile engine holds neither.
pub const owner_lock = @import("owner_lock.zig");
pub const Admission = @import("admission.zig").Admission;
