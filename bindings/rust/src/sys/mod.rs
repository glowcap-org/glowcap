//! The raw FFI mirror of the C ABI, grouped per archive (ADR-0059).
//!
//! glowcap's C ABI ships as a set of symbol-disjoint archives, and this module
//! mirrors that shape: [`ocapn`] is the always-linked core (`libglowcap_ocapn`),
//! [`host`] is the byte-fed host archive (`libglowcap_host`, ADR-0072), and
//! each transport's externs live in their own submodule behind the matching
//! Cargo feature, so a build declares the FFI for exactly the archives it links.
//! Nothing in here escapes the crate; the safe wrappers above wrap it.
//!
//! The core and transport mirrors are deliberately wider than what the
//! wrappers call (each says so with its own file-wide `allow(dead_code)`): an
//! extern declared here counts as a consumer for `zig build source-check`'s
//! every-C-export-has-a-consumer gate, so the declaration set doubles as the
//! crate's statement of which ABI symbols it stands behind. Prune an extern
//! only together with the C export it mirrors. The [`host`] mirror carries
//! no such allow: it compiles only beside its `async` users, every decl has a
//! caller, and the crate's `dead_code = "deny"` lint refuses a decl whose
//! caller goes away.
//!
//! The shared frame, context, and value types are declared once in [`ocapn`]
//! and re-exported here, because the driver and transport archives agree on
//! their *layout* rather than re-exporting the symbols.

#[cfg(all(feature = "async", not(target_arch = "wasm32")))]
pub mod driver;
#[cfg(feature = "async")]
pub mod host;
#[cfg_attr(target_arch = "wasm32", path = "wasm_layouts_gen.rs")]
pub(crate) mod layouts_gen;
mod ocapn;
pub use ocapn::*;
#[cfg(all(
	not(target_arch = "wasm32"),
	any(feature = "async", feature = "tcp", feature = "onion", feature = "webrtc")
))]
mod provider;
#[cfg(all(
	not(target_arch = "wasm32"),
	any(feature = "async", feature = "tcp", feature = "onion", feature = "webrtc")
))]
pub use provider::*;

#[cfg(all(feature = "async", not(target_arch = "wasm32")))]
mod driver_fns_gen;
#[cfg(feature = "async")]
mod host_fns_gen;
mod ocapn_fns_gen;

pub use crate::abi_constants::*;

#[cfg(feature = "inproc")]
pub mod inproc;
#[cfg(feature = "inproc")]
mod inproc_fns_gen;
#[cfg(feature = "iroh")]
pub mod iroh;
#[cfg(feature = "iroh")]
mod iroh_fns_gen;
#[cfg(feature = "onion")]
pub mod onion;
#[cfg(feature = "onion")]
mod onion_fns_gen;
#[cfg(feature = "relay")]
pub mod relay;
#[cfg(feature = "relay")]
mod relay_fns_gen;
#[cfg(feature = "tcp")]
pub mod tcp;
#[cfg(feature = "tcp")]
mod tcp_fns_gen;
#[cfg(feature = "webrtc")]
pub mod webrtc;
#[cfg(feature = "webrtc")]
mod webrtc_fns_gen;

#[cfg(feature = "loam")]
pub mod loam;
