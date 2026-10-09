//! Host effects for Rooms services.
//!
//! This crate supplies Tokio scheduling, operating-system entropy, durable
//! filesystem operations, listeners, TLS, and WebSocket byte channels. It
//! contains no Rooms product or service policy.
pub mod execution;
pub use entropy::OsEntropy;
pub mod entropy;
pub mod serving;
pub mod storage;
pub mod tls;
pub mod trace;
pub mod websocket;

pub use execution::HostPlatform;
