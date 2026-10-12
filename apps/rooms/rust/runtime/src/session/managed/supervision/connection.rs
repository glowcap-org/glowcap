//! A lost exporter retires only its exact connection-lived custody selections.
use super::*;

impl<P: Tasks + Deadline + Clone + 'static> Worker<P> {
	pub(super) async fn observe_direct_connection(&mut self, operation: &str) -> Result<bool> {
		if !matches!(self.selected, workspace::InboxSelection::Direct { .. }) {
			return Ok(true);
		}
		let selection = serde_json::to_string(&self.selected).map_err(|_| loam::refusal("invalid direct selection"))?;
		let args = [
			self.writer.root()?.into(),
			selection.into(),
			self.inbox.reference().clone().into(),
			operation.into(),
		];
		let writer = self.writer.clone();
		let endpoint = self.workspace.reference().clone();
		Ok(self
			.stage(|| async {
				writer
					.host
					.send(&endpoint, "observe-direct-connection", &args)
					.await
					.map_err(|failure| failure.with_context("observing the direct route exporter"))
			})
			.await?
			.is_some())
	}
	/// Replacing callback/source custody retires its worker, while the open
	/// conversation can still use the same channel through its successor. Only
	/// closing or removing the conversation authorizes transport retirement.
	pub(super) async fn direct_retired(&self) -> Result<bool> {
		let workspace::InboxSelection::Direct { id, .. } = &self.selected else {
			return Ok(false);
		};
		let root = Workspace::local(self.writer.host.clone(), self.platform.clone(), self.writer.root()?);
		let snapshot = root.owner_snapshot(&self.writer.root()?).await.map_err(error)?;
		Ok(!snapshot
			.intent
			.conversations
			.as_slice()
			.iter()
			.any(|row| matches!(row, workspace::Conversation::Direct(row) if row.id == *id && !row.closed)))
	}
	pub(super) async fn expire_connection_lease(&mut self) -> Result<()> {
		let Some(lease) = self.lease else { return Ok(()) };
		self.recovery.recover();
		loop {
			let mut snapshot = self
				.workspace
				.owner_snapshot(&self.writer.root()?)
				.await
				.map_err(error)?;
			let mut changed = false;
			match lease {
				Lease::Direct(inbox) => {
					for row in snapshot.intent.conversations.as_mut_slice() {
						if let workspace::Conversation::Direct(row) = row
							&& row.inbox == Some(inbox)
						{
							row.closed = true;
							row.inbox = None;
							row.access = None;
							row.lines = Default::default();
							changed = true;
						}
					}
				}
				Lease::Directory(name) => {
					for row in snapshot.intent.directories.as_mut_slice() {
						if row.name == Some(name) {
							row.name = None;
							row.assigned_nick = None;
							row.inbox = None;
							changed = true;
						}
					}
				}
				Lease::Room(seat) => {
					for row in snapshot.intent.conversations.as_mut_slice() {
						if let workspace::Conversation::Room(row) = row
							&& row.seat == Some(seat)
						{
							row.seat = None;
							row.topic = None;
							row.files = None;
							row.inbox = None;
							row.lines = Default::default();
							changed = true;
						}
					}
				}
			}
			if !changed {
				return Ok(());
			}
			// Configuration replacement retires every now-unselected coordinate
			// without a second field inventory. Durable entrance, control, source,
			// history and explicit reconnect choice stay in their existing rows.
			let acquisition =
				self.workspace
					.prepare_owner_acquisition(&self.writer.root()?, snapshot.revision, &snapshot.intent)?;
			drop(snapshot);
			loop {
				match acquisition.submit().await {
					Ok(()) => return Ok(()),
					Err(rooms_glowcap::client::Error::WorkspaceConflict) => break,
					Err(failure) => {
						// Keep this exact candidate through uncertainty. Only proved
						// conflict permits preparation against a newer revision.
						self.finished.send_replace(Some(Err(error(failure))));
						tokio::select! {
							_ = self.stopping.changed() => {},
							_ = self.retrying.changed() => {},
						}
					}
				}
			}
		}
	}
}
