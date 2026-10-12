//! Runtime plumbing shared by the Rust transport sidecars (ADR-0055, ADR-0089).
//!
//! Each sidecar wraps an async crate behind a synchronous C ABI, and three
//! pieces of that shape are the same whichever crate sits behind it:
//!
//! * `RuntimeOwner` holds the endpoint's private Tokio runtime and runs one C
//!   call on it, even when the call arrives from inside another runtime.
//! * `TaskBarrier` lets a task outlive the handle that spawned it and still
//!   report its outcome to endpoint release.
//! * `Readiness` is the self-pipe plus coalescing record queue behind each
//!   sidecar's readiness fd.
//!
//! Nothing here names a transport or exports a C symbol. Each sidecar keeps its
//! own `#[repr(C)]` readiness record and its own `glowcap_*_sidecar_*` family.
//! `Readiness` is generic over that record so the queue is shared and the C
//! layout is not.

mod barrier;
mod readiness;
mod runtime;

pub use barrier::{TaskBarrier, TaskFailure, TaskPermit};
pub use readiness::Readiness;
pub use runtime::RuntimeOwner;
