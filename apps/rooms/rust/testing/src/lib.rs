//! Test support shared by the Rooms crates' own tests: the guards and runner
//! that every crate would otherwise write again. A crate takes this as a
//! dev-dependency only; nothing here ships in a Rooms executable, and the
//! browser build never links it.

pub mod child_process;
pub mod local_set;
pub mod scratch;
