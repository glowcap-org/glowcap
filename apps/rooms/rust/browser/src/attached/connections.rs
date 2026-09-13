//! Browser clients use the shared per-peer connection owner.
use crate::platform::Platform;
use tokio::sync::watch;
pub(super) type Connections = rooms_runtime::directories::connections::Connections<Platform>;
pub(super) type Connection = rooms_runtime::directories::connections::Connection<Platform>;
pub(super) type Terminal = rooms_runtime::directories::connections::Terminal;
pub(super) use rooms_runtime::directories::connections::terminal;

/// Wait for a browser-owned task to report how it ended.
///
/// This is the sibling of the runtime's `terminal`, not a copy of it: these
/// outcomes belong to tasks this module spawned and their reader is the page,
/// so they carry the sentence JavaScript will see rather than the runtime's
/// classed failure. A sender dropped without reporting means the task was
/// cancelled with nobody left to say why.
pub(super) async fn settled(ended: &mut watch::Receiver<Option<super::Result<()>>>) -> super::Result<()> {
	while ended.borrow().is_none() {
		ended
			.changed()
			.await
			.map_err(|_| "a Rooms browser owner retired without reporting".to_owned())?;
	}
	ended.borrow().as_ref().expect("settled owner").clone()
}
