//! Reflected layouts and extern functions for the optional Loam archives.
#[path = "loam_gen.rs"]
mod layouts;
pub use layouts::*;
#[path = "loam_fns_gen.rs"]
mod portable;
pub use portable::*;
#[cfg(not(target_arch = "wasm32"))]
#[path = "loam_lmdb_fns_gen.rs"]
mod storage;
#[cfg(not(target_arch = "wasm32"))]
pub use storage::*;
