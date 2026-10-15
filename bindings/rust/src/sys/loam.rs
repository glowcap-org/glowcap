//! Reflected layouts and extern functions for the optional Loam archives.
#[path = "loam_gen.rs"]
mod layouts;
pub use layouts::*;
#[path = "loam_fns_gen.rs"]
mod portable;
pub use portable::*;
#[cfg(not(target_arch = "wasm32"))]
#[path = "loam_lmdb_fns_gen.rs"]
mod lmdb_storage;
#[cfg(not(target_arch = "wasm32"))]
pub use lmdb_storage::*;
#[cfg(not(target_arch = "wasm32"))]
#[path = "loam_sqlite_fns_gen.rs"]
mod sqlite_storage;
#[cfg(not(target_arch = "wasm32"))]
pub use sqlite_storage::*;
#[cfg(not(target_arch = "wasm32"))]
#[path = "loam_volatile_fns_gen.rs"]
mod volatile_storage;
#[cfg(not(target_arch = "wasm32"))]
pub use volatile_storage::*;
