//! Room standing and member profiles follow saved intent through the
//! membership's exact source. One bounded pending command survives interruption.
//! An acknowledged value is never redispatched on unrelated workspace changes.
use super::*;
use rooms_application::{content::permissions::Permission, room::profile::MemberProfile};
use rooms_glowcap::client::workspace::{Command, Snapshot};

#[cfg(test)]
#[cfg(not(target_arch = "wasm32"))]
mod tests;

enum Preference {
	Standing(String),
	Profile(MemberProfile),
}
/// Retain the acknowledged bounded preferences and at most one submitted change.
/// Forgetting either would resend
/// unchanged preferences or replace an uncertain operation with newer intent.
/// One Rc shell lends the exact Command to waits while this owner keeps it.
/// Worker.submission owns actual admission. Existing membership and effect
/// limits bound the population. Empty standing allocates no string backing.
pub(super) struct Preferences<P> {
	away: String,
	profile: MemberProfile,
	generation: u64,
	pending: Option<(Preference, Rc<Command<P>>)>,
}
impl<P> Default for Preferences<P> {
	fn default() -> Self {
		Self {
			away: String::new(),
			profile: MemberProfile::default(),
			generation: 0,
			pending: None,
		}
	}
}
impl<P: Tasks + Deadline + Clone + 'static> Worker<P> {
	/// Consume the wake's owned snapshot for selection and preferences together.
	/// Nothing is cached between wakes. A pending command discards that input:
	/// after settlement or a proved conflict, only a fresh read may select intent.
	pub(super) async fn apply_preferences(&mut self, operation: &str, mut snapshot: Option<Snapshot>) -> Result<bool> {
		let workspace::InboxSelection::Room { id, .. } = &self.selected else {
			return Ok(true);
		};
		let id = id
			.text()
			.as_str()
			.ok_or_else(|| Error::invalid("invalid preference room"))?
			.to_owned();
		let mut conflicts = 0;
		if self.preferences.pending.is_some() {
			snapshot.take();
		}
		'intent: loop {
			if self.preferences.pending.is_none() {
				let snapshot = match snapshot.take() {
					Some(snapshot) => snapshot,
					None => {
						let workspace = self.workspace.clone();
						let owner = self.writer.root()?;
						let Some(snapshot) = self
							.stage(|| async { workspace.owner_snapshot(&owner).await.map_err(Error::from) })
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
				let Some(room) = snapshot.intent.room(&id).filter(|room| room.seat == Some(seat)) else {
					return Ok(false);
				};
				let reason = snapshot
					.intent
					.room_standing(&id)
					.and_then(|value| value.text().as_str())
					.ok_or_else(|| Error::closed("preference room was retired"))?;
				let (preference, verb, args) = if reason != self.preferences.away {
					(
						Preference::Standing(reason.to_owned()),
						"setRoomAway",
						vec![id.clone(), reason.into()],
					)
				} else if room.profile != self.preferences.profile
					&& self
						.retirement
						.as_ref()
						.filter(|owner| !owner.room_ended.get())
						.and_then(|owner| owner.profile.as_ref())
						.is_some_and(|(profile, _)| profile.supports(seat))
				{
					// A saved declaration cannot widen the exact source which joined
					// this room. A posting-only membership still reconciles standing.
					let workspace = self.workspace.clone();
					let Some(access) = self
						.stage(|| async { workspace.describe_access().await.map_err(Error::from) })
						.await?
					else {
						return Ok(false);
					};
					if !matches!(access.view(), loam::UseDescription::Active(source)
						if source.effective.permissions().any(|p| p == Permission::ReplaceWorkspace.key()))
					{
						self.rate_retry.reset();
						return Ok(true);
					}
					let expected =
						serde_json::to_string(&seat).map_err(|_| Error::invalid("invalid profile seat coordinate"))?;
					(
						Preference::Profile(room.profile.clone()),
						"applyRoomProfile",
						vec![
							id.clone(),
							expected,
							room.profile.kind.as_str().into(),
							room.profile.about().into(),
						],
					)
				} else {
					// Confirmed current intent ends this recovery incident. A later
					// refusal gets its own finite window; pending retries cannot reset it.
					self.rate_retry.reset();
					return Ok(true);
				};
				self.preferences.generation = self
					.preferences
					.generation
					.checked_add(1)
					.ok_or_else(|| Error::exhausted("preference operation space exhausted"))?;
				let command = self
					.workspace
					.prepare_command(
						&format!("{operation}:preference:{}", self.preferences.generation),
						snapshot.revision,
						verb,
						&args,
					)
					.await
					.map_err(Error::from)?;
				self.preferences.pending = Some((preference, Rc::new(command)));
			}
			let command = self
				.preferences
				.pending
				.as_ref()
				.ok_or_else(|| Error::closed("preference command is not retained"))?
				.1
				.clone();
			self.submission.get_or_insert_with(|| command.start_submission());
			let admitted = loop {
				let outcome = tokio::select! {
					biased;
					_ = self.stopping.changed() => return Ok(false),
					outcome = self.submission.as_mut().ok_or_else(|| Error::closed("room preference admission is not owned"))?.within(
						&self.platform, rooms_application::room::authority::REQUEST_TIMEOUT_MS) => outcome,
				};
				match outcome {
					Some(Ok(status)) => {
						self.submission.take();
						break status;
					}
					Some(Err(failure)) => {
						self.submission.take();
						if !self.failed(Error::from(failure)).await? {
							return Ok(false);
						}
						self.submission = Some(command.start_submission());
					}
					None => {
						if !self
							.failed(Error::uncertain("room preference admission remains pending"))
							.await?
						{
							return Ok(false);
						}
					}
				}
			};
			if admitted == EffectStatus::Conflict {
				self.preferences.pending.take();
				conflicts += 1;
				if conflicts == 4 {
					return Err(Error::stale("room preference admission repeatedly conflicted"));
				}
				continue;
			}
			loop {
				let Some(status) = self
					.stage(|| async { command.status().await.map_err(Error::from) })
					.await?
				else {
					return Ok(false);
				};
				match status {
					EffectStatus::Committed => break,
					EffectStatus::Unsent => {
						// Confirmed absence permits a new command, but never a
						// replay of this obsolete preference. Keep its terminal
						// receipt in the bounded recovery window and reread intent
						// after the existing worker's cancellable cooldown.
						let failure = command
							.result()
							.await
							.err()
							.map(Error::from)
							.unwrap_or_else(|| Error::uncertain("Room preference was not sent"));
						if !self.failed(failure).await? {
							return Ok(false);
						}
						self.preferences.pending.take();
						self.ready.send_replace(self.live.then_some(Ok(())));
						continue 'intent;
					}
					EffectStatus::Pending => {
						if !self.changed().await? {
							return Ok(false);
						}
					}
					_ => {
						if !self
							.failed(Error::uncertain(
								"room preference requires recovery of its original receipt",
							))
							.await?
						{
							return Ok(false);
						}
					}
				}
			}
			match self
				.preferences
				.pending
				.take()
				.ok_or_else(|| Error::closed("confirmed room preference is not retained"))?
				.0
			{
				Preference::Standing(value) => self.preferences.away = value,
				Preference::Profile(value) => self.preferences.profile = value,
			}
			// A newer preference may have arrived while this receipt settled.
		}
	}
}
