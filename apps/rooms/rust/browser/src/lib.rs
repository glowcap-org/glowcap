//! Browser platform execution for the shared Rooms application. Application
//! policy and capability clients remain in rooms-application and rooms-glowcap.
#![forbid(unsafe_code)]

#[cfg(target_arch = "wasm32")]
mod abort;
#[cfg(target_arch = "wasm32")]
mod attached;
#[cfg(target_arch = "wasm32")]
mod commands;
#[cfg(target_arch = "wasm32")]
mod entry;
#[cfg(target_arch = "wasm32")]
mod workspace_persistence;

#[cfg(target_arch = "wasm32")]
pub mod ice;
#[cfg(target_arch = "wasm32")]
pub mod platform;
#[cfg(target_arch = "wasm32")]
pub mod signaling;

#[cfg(target_arch = "wasm32")]
pub mod storage;

#[cfg(target_arch = "wasm32")]
pub mod transport;

#[cfg(target_arch = "wasm32")]
mod viz;

#[cfg(target_arch = "wasm32")]
mod operations_bundle;

#[cfg(target_arch = "wasm32")]
mod slash;

#[cfg(target_arch = "wasm32")]
mod forms;

#[cfg(target_arch = "wasm32")]
mod text;
