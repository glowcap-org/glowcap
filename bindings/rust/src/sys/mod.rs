//! The raw FFI mirror of the C ABI, grouped per archive (ADR-0059).
//!
//! pancake's C ABI ships as a set of symbol-disjoint archives, and this module
//! mirrors that shape: [`ocapn`] is the always-linked core (`libpancake_ocapn`),
//! [`driver`] is the byte-fed host archive (`libpancake_driver`, ADR-0072), and
//! each transport's externs live in their own submodule behind the matching
//! Cargo feature, so a build declares the FFI for exactly the archives it links.
//! Nothing in here escapes the crate; the safe wrappers above wrap it.
//!
//! The core and transport mirrors are deliberately wider than what the
//! wrappers call (each says so with its own file-wide `allow(dead_code)`): an
//! extern declared here counts as a consumer for `zig build meta-check`'s
//! every-C-export-has-a-consumer gate, so the declaration set doubles as the
//! crate's statement of which ABI symbols it stands behind. Prune an extern
//! only together with the C export it mirrors. The [`driver`] mirror carries
//! no such allow: it compiles only beside its `async` users, every decl has a
//! caller, and the crate's `dead_code = "deny"` lint refuses a decl whose
//! caller goes away.
//!
//! The shared frame, context, and value types are declared once in [`ocapn`]
//! and re-exported here, because the driver and transport archives agree on
//! their *layout* rather than re-exporting the symbols.

#[cfg(feature = "async")]
pub mod driver;
mod layouts_gen;
mod ocapn;
pub use ocapn::*;

pub use crate::abi_constants::*;

#[cfg(feature = "inproc")]
pub mod inproc;
#[cfg(feature = "iroh")]
pub mod iroh;
#[cfg(feature = "tcp")]
pub mod tcp;
