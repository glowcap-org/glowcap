//! Read a checkpoint file for host executable startup.
use crate::session::error::Error;
use rooms_application::session::checkpoint::{Checkpoint, MAX_CHECKPOINT_UNITS};
use rooms_runtime::service::verbs::checkpoint::import_document;
use std::io::Read;
use std::path::Path;
/// Read the workspace or session document that shared startup adopts as revision one. A
/// workspace export carries its session under `session`; a bare session
/// document is accepted as it is.
pub async fn read(path: &Path) -> Result<Checkpoint, Error> {
	let raw = tokio::task::spawn_blocking({
		let path = path.to_owned();
		move || {
			let mut raw = String::new();
			std::fs::File::open(path)?
				.take((3 * MAX_CHECKPOINT_UNITS + 1) as u64)
				.read_to_string(&mut raw)?;
			Ok::<_, std::io::Error>(raw)
		}
	})
	.await
	.map_err(|join| Error::uncertain(format!("the checkpoint import worker failed: {join}")))?
	.map_err(Error::io("checkpoint import"))?;
	if raw.encode_utf16().take(MAX_CHECKPOINT_UNITS + 1).count() > MAX_CHECKPOINT_UNITS {
		return Err(Error::refused("checkpoint import exceeds its text ceiling"));
	}
	let checkpoint = import_document(&raw).map_err(|refusal| {
		Error::refused(format!(
			"checkpoint {} is not a complete Rooms workspace or session state: {refusal}",
			path.display()
		))
	})?;
	Ok(checkpoint)
}
