//! Standing follows persisted room, directory and workspace intent through the
//! membership's exact source. One bounded pending command survives interruption;
//! an acknowledged value is never redispatched on unrelated workspace changes.
use super::*;
use rooms_glowcap::client::workspace::{Command, Snapshot};

#[cfg(all(test, not(target_arch = "wasm32")))]
mod tests;

/// Retain the acknowledged setting and at most one submitted setting, each
/// bounded by the application's Standing type. Forgetting either would resend
/// unchanged preferences or replace an uncertain operation with newer intent.
/// One Rc shell lends the exact Command to waits while this owner keeps it;
/// Worker.submission owns actual admission. Existing membership and effect
/// limits bound the population. Empty standing allocates no string backing.
pub(super) struct Standing<P> {
	applied: String,
	generation: u64,
	pending: Option<(String, Rc<Command<P>>)>,
}
impl<P> Default for Standing<P> {
	fn default() -> Self {
		Self {
			applied: String::new(),
			generation: 0,
			pending: None,
		}
	}
}
impl<P: Tasks + Deadline + Clone + 'static> Worker<P> {
	/// Consume the wake's owned snapshot for selection and standing together.
	/// Nothing is cached between wakes. A pending command discards that input:
	/// after settlement or a proved conflict, only a fresh read may select intent.
	pub(super) async fn apply_standing(&mut self, operation: &str, mut snapshot: Option<Snapshot>) -> Result<bool> {
		let workspace::InboxSelection::Room { id, .. } = &self.selected else {
			return Ok(true);
		};
		let id = id
			.text()
			.as_str()
			.ok_or_else(|| loam::refusal("invalid standing room"))?
			.to_owned();
		let mut conflicts = 0;
		if self.standing.pending.is_some() {
			snapshot.take();
		}
		loop {
			if self.standing.pending.is_none() {
				let snapshot = match snapshot.take() {
					Some(snapshot) => snapshot,
					None => {
						let workspace = self.workspace.clone();
						let Some(snapshot) = self
							.stage(|| async { workspace.snapshot().await.map_err(error) })
							.await?
						else {
							return Ok(false);
						};
						snapshot
					}
				};
				if !self.selected.matches(&snapshot.intent) {
					return Ok(false);
				}
				let Some(Lease::Room(seat)) = self.lease else {
					return Ok(false);
				};
				if !snapshot.intent.conversations.as_slice().iter().any(|row| {
					matches!(row, workspace::Conversation::Room(room)
						if room.id.text().as_str() == Some(id.as_str()) && room.seat == Some(seat))
				}) {
					return Ok(false);
				}
				let reason = snapshot
					.intent
					.room_standing(&id)
					.and_then(|value| value.text().as_str())
					.ok_or_else(|| loam::refusal("standing room was retired"))?;
				if reason == self.standing.applied {
					return Ok(true);
				}
				self.standing.generation = self
					.standing
					.generation
					.checked_add(1)
					.ok_or_else(|| loam::refusal("standing operation space exhausted"))?;
				let command = self
					.workspace
					.prepare_command(
						&format!("{operation}:standing:{}", self.standing.generation),
						snapshot.revision,
						"setRoomAway",
						&[id.clone(), reason.into()],
					)
					.await
					.map_err(error)?;
				self.standing.pending = Some((reason.into(), Rc::new(command)));
			}
			let command = self.standing.pending.as_ref().expect("retained standing").1.clone();
			self.submission.get_or_insert_with(|| command.start_submission());
			let admitted = loop {
				let outcome = tokio::select! {
					biased;
					_ = self.stopping.changed() => return Ok(false),
					outcome = self.submission.as_mut().expect("standing admission").within(
						&self.platform, rooms_application::room::authority::REQUEST_TIMEOUT_MS) => outcome,
				};
				match outcome {
					Some(Ok(status)) => {
						self.submission.take();
						break status;
					}
					Some(Err(failure)) => {
						self.submission.take();
						if !self.failed(error(failure)).await? {
							return Ok(false);
						}
						self.submission = Some(command.start_submission());
					}
					None => {
						if !self.failed(loam::refusal("standing admission remains pending")).await? {
							return Ok(false);
						}
					}
				}
			};
			if admitted == EffectStatus::Conflict {
				self.standing.pending.take();
				conflicts += 1;
				if conflicts == 4 {
					return Err(loam::refusal("standing admission repeatedly conflicted"));
				}
				continue;
			}
			loop {
				let Some(status) = self.stage(|| async { command.status().await.map_err(error) }).await? else {
					return Ok(false);
				};
				match status {
					EffectStatus::Committed => break,
					EffectStatus::Pending => {
						if !self.changed().await? {
							return Ok(false);
						}
					}
					_ => {
						if !self
							.failed(loam::refusal("standing requires recovery of its original receipt"))
							.await?
						{
							return Ok(false);
						}
					}
				}
			}
			self.standing.applied = self.standing.pending.take().expect("confirmed standing").0;
			// A newer preference may have arrived while this receipt settled.
		}
	}
}
