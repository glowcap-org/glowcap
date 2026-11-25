//! Test support shared by the Rooms crates' own tests: the guards, runner and clock
//! that every crate would otherwise write again. A crate takes this as a
//! dev-dependency, and the browser proof host links it for the write gate.
//! Nothing here ships in a Rooms executable or the browser bundle.

pub mod child_process;
pub mod deadline;
pub mod local_set;
pub mod scratch;
pub mod write_gate;
