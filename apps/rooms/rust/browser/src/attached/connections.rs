//! Browser clients use the shared per-peer connection owner.
use crate::platform::Platform;
pub(super) type Connections = rooms_runtime::connections::Connections<Platform>;
pub(super) type Connection = rooms_runtime::connections::Connection<Platform>;
pub(super) use rooms_runtime::connections::terminal;
