//! Disabling history erases before committing its checkpoint, fencing new
//! recordings through the storage write. Restoring a disabled checkpoint also
//! erases remnants before readiness. The archive owns FIFO disk effects.
use crate::{session_archive::SessionArchive, session_commands::SessionEvents, session_state::SessionView};
use rooms_application::archive::retention::Retention;
use rooms_application::session::{
	checkpoint::{commands::Facts, reconciliation::Fact},
	state::Change,
};
use std::rc::Rc;

pub struct RetentionEvents<E, P: crate::platform::Platform> {
	inner: E,
	archive: Rc<SessionArchive<P>>,
	retention: Retention,
	selected: Option<String>,
	/// A target opened for a candidate checkpoint. The next settlement either
	/// realizes the committed selection or discards an uncommitted preparation.
	prepared_selection: bool,
}
impl<E: SessionEvents, P: crate::platform::Platform> RetentionEvents<E, P> {
	/// Drive the archive worker before opening this adapter, and complete this
	/// initialization before publishing session archive or command capabilities.
	/// A restored disabled checkpoint erases local remnants before readiness.
	pub async fn open(inner: E, archive: Rc<SessionArchive<P>>, view: &SessionView) -> Result<Self, String> {
		let keep = keeps_history(view)?;
		let mut owner = Self {
			inner,
			archive,
			retention: Retention::restore(keep),
			selected: None,
			prepared_selection: false,
		};
		// A stored peer is durable intent, not proof of reachability. Restore it
		// into the archive's explicit unavailable state when dialing fails, then
		// publish the session so its issue can be repaired rather than replacing
		// the chosen peer with the local backend.
		if let Err(error) = owner.settle_selection(view).await {
			// Only a worker-owned selection refusal establishes the explicit
			// unavailable state. Admission/worker loss has no such outcome owner.
			if owner.archive.selection_issue().is_none() {
				return Err(error);
			}
		}
		owner.settle_retention(view).await?;
		owner.inner.settled(view).await?;
		Ok(owner)
	}
	async fn settle_selection(&mut self, view: &SessionView) -> Result<(), String> {
		let wanted = archive_peer(view)?;
		if wanted == self.selected && !self.prepared_selection {
			return Ok(());
		}
		self.archive.select(wanted.clone())?.wait().await?;
		self.selected = wanted;
		self.prepared_selection = false;
		Ok(())
	}
	async fn settle_retention(&mut self, view: &SessionView) -> Result<(), String> {
		let keep = keeps_history(view)?;
		self.retention.observe(keep);
		if self.retention.requires_erasure() {
			self.archive.clear_local_when_ready().await?;
			self.retention.erased();
		}
		Ok(())
	}
}
fn keeps_history(view: &SessionView) -> Result<bool, String> {
	view.read(|state| state.checkpoint().map(|checkpoint| checkpoint.keeps_history()))
		.map_err(|e| e.to_string())?
		.map_err(|e| e.to_string())
}
fn archive_peer(view: &SessionView) -> Result<Option<String>, String> {
	view.read(|state| {
		state.checkpoint().map(|checkpoint| {
			checkpoint
				.archive_peer()
				.and_then(|peer| peer.as_str())
				.map(str::to_owned)
		})
	})
	.map_err(|e| e.to_string())?
	.map_err(|e| e.to_string())
}
impl<E: SessionEvents, P: crate::platform::Platform> SessionEvents for RetentionEvents<E, P> {
	async fn preparing(
		&mut self,
		checkpoint: &rooms_application::session::checkpoint::Checkpoint,
	) -> Result<impl Sized + 'static, String> {
		let inner = self.inner.preparing(checkpoint).await?;
		let archive = checkpoint
			.archive_peer()
			.and_then(|peer| peer.as_str())
			.map(str::to_owned);
		if archive != self.selected {
			if let Some(link) = archive {
				self.archive
					.prepare(link)
					.map_err(|error| error.to_string())?
					.wait()
					.await?;
				self.prepared_selection = true;
			}
		}
		let pause = if self.retention.disables(checkpoint.keeps_history()) {
			let pause = self.archive.pause_recording();
			self.archive.clear_local_when_ready().await?;
			self.retention.observe(false);
			self.retention.erased();
			Some(pause)
		} else {
			None
		};
		Ok((inner, pause))
	}

	fn facts(&self) -> impl Facts + '_ {
		self.inner.facts()
	}
	fn changed(&mut self, change: Change, view: &SessionView) {
		self.inner.changed(change, view);
	}
	async fn settled(&mut self, view: &SessionView) -> Result<(), String> {
		self.settle_selection(view).await?;
		self.settle_retention(view).await?;
		self.inner.settled(view).await
	}
	fn reconciliation_issue(&mut self, fact: &Fact, error: Option<&str>) {
		self.inner.reconciliation_issue(fact, error);
	}
}
