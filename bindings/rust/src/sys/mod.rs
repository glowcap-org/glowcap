//! The raw FFI mirror of the C ABI, grouped per archive (ADR-0059).
//!
//! pancake's C ABI ships as a set of symbol-disjoint archives, and this module
//! mirrors that shape: [`ocapn`] is the always-linked core (`libpancake_ocapn`),
//! and each transport's externs live in their own submodule behind the matching
//! Cargo feature, so a build declares the FFI for exactly the archives it links.
//! Nothing in here escapes the crate; the safe wrappers above wrap it.
//!
//! The mirror is deliberately wider than what the wrappers call: an extern
//! declared here counts as a consumer for `zig build meta-check`'s
//! every-C-export-has-a-consumer gate, so the declaration set doubles as the
//! crate's statement of which ABI symbols it stands behind. Prune an extern
//! only together with the C export it mirrors.
//!
//! The shared frame, context, and value types are declared once in [`ocapn`]
//! and re-exported here, because the transport archives agree on their *layout*
//! rather than re-exporting the symbols.

mod ocapn;
pub use ocapn::*;

pub use crate::abi_constants::*;

#[cfg(feature = "inproc")]
pub mod inproc;
#[cfg(feature = "iroh")]
pub mod iroh;
#[cfg(feature = "tcp")]
pub mod tcp;
