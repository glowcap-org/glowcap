//! Browser platform execution for the shared Rooms application. Application
//! policy and capability clients remain in rooms-application and rooms-glowcap.
//! Everything here targets the browser, so the whole crate compiles to an empty
//! library on other targets and a workspace-wide `cargo` command still succeeds.
#![cfg(target_arch = "wasm32")]

mod abort;
mod attached;
mod entry;
mod forms;
mod history;
mod js_text;
mod nickname;
mod operations_bundle;
mod slash;
mod text;
mod trace;

pub mod ice;
pub mod platform;
pub mod signaling;
pub mod storage;
pub mod transport;
