//! The checkpoint-to-live diff: which intended rooms to start joining, which
//! live ones no longer match their intent and must go, and which join
//! attempts to keep. Runs on every checkpoint or directory change.
use super::*;

impl<P: Platform> RoomWorker<P> {
	pub(super) async fn reconcile(&mut self) -> Result<(), Error> {
		let wanted = self.wanted()?;
		let retired_entry = {
			let mut state = self.shared.borrow_mut();
			if state.entry.as_ref().is_some_and(|entry| {
				entry.committed
					&& wanted
						.get(&entry.wanted.intent.id)
						.is_none_or(|want| want.intent != entry.wanted.intent)
			}) {
				state.entry.take()
			} else {
				None
			}
		};
		if let Some(entry) = retired_entry {
			entry.room.leave().await.map_err(Error::peer)?;
		}
		let (stale, start) = {
			let mut state = self.shared.borrow_mut();
			state
				.joining
				.retain(|id, attempt| wanted.get(id).is_some_and(|want| want.intent == attempt.intent));
			state
				.terminal
				.retain(|id, ended| wanted.get(id).is_some_and(|want| want.intent.remains_terminal(ended)));
			let mut stale = Vec::new();
			for id in state.rooms.keys().cloned().collect::<Vec<_>>() {
				let keep = wanted.get(&id).is_some_and(|want| {
					state.rooms.get(&id).is_some_and(|live| {
						live.scope.current()
							&& live.intent.same_membership(&want.intent)
							&& self
								.directories
								.connected(&want.intent.directory)
								.is_some_and(|(directory, nick)| {
									nick == live.nick
										&& directory.client().session().same_session(live.room.client().session())
								})
					}) && want.intent.reconnect != Some(RoomReconnect::Requested)
				});
				if !keep && let Some(live) = state.rooms.remove(&id) {
					stale.push(live);
				}
			}
			let mut start = Vec::new();
			for (id, want) in &wanted {
				if state.rooms.contains_key(id)
					|| state.joining.contains_key(id)
					|| state
						.terminal
						.get(id)
						.is_some_and(|ended| want.intent.remains_terminal(ended))
				{
					continue;
				}
				// Keep the already-subscribed stream buffered until its directory
				// registration is installed. Installing earlier would give the live
				// membership an empty nick and retire it on the next directory tick.
				if state
					.entry
					.as_ref()
					.is_some_and(|entry| entry.wanted.intent == want.intent)
					&& self.directories.connected(&want.intent.directory).is_none()
				{
					continue;
				}
				match want.blocked() {
					Ok(()) => {
						state.issues.remove(&want.intent.subject);
						let mut want = want.clone();
						if self.completed.len() + start.len() >= 32 {
							self.retry_at = Some(self.platform.now() + REJOIN_DELAY);
							continue;
						}
						if let Some(entry) = state.entry.as_ref().filter(|entry| entry.wanted.intent == want.intent) {
							want.epoch = entry.wanted.epoch;
						} else {
							want.epoch = state.next_epoch;
							state.next_epoch = state
								.next_epoch
								.checked_add(1)
								.ok_or_else(|| Error::exhausted("room membership epoch exhausted"))?;
						}
						state.joining.insert(id.clone(), want.clone());
						start.push(want);
					}
					Err(error) => {
						state.issues.insert(want.intent.subject.clone(), error.to_string());
					}
				}
			}
			(stale, start)
		};
		for live in stale {
			self.retire_live(live).await;
		}
		for want in wanted.values() {
			self.reconcile_custody(want).await?;
		}
		for want in start {
			let staged = {
				let mut state = self.shared.borrow_mut();
				if state
					.entry
					.as_ref()
					.is_some_and(|entry| entry.wanted.intent == want.intent)
				{
					state.entry.take()
				} else {
					None
				}
			};
			if let Some(staged) = staged {
				self.completed
					.spawn_local(async move { Finished::Ready(Box::new(staged)) });
				continue;
			}
			let directories = self.directories.clone();
			let events = self.events.clone();
			let notices = self.notices.clone();
			let shared = self.shared.clone();
			self.completed.spawn_local(joining::join(
				self.entropy.clone(),
				directories,
				events,
				notices,
				shared,
				want,
			));
		}
		self.reconcile_bridges().await;
		self.changed.send_replace(());
		Ok(())
	}
	/// Every room the checkpoint intends, by conversation id.
	pub(super) fn wanted(&self) -> Result<HashMap<String, Wanted>, Error> {
		self.commands.view().read(|state| {
			Ok(state
				.checkpoint()?
				.rooms()
				.filter_map(intent::Intent::read)
				.map(|intent| (intent.id.clone(), Wanted { intent, epoch: 0 }))
				.collect())
		})?
	}
	/// Whether a finished join is the one the worker is waiting for: its
	/// attempt is the current one for that room and the checkpoint still
	/// intends the same membership.
	pub(super) fn accepts(&self, wanted: &Wanted) -> Result<bool, Error> {
		let state = self.shared.borrow();
		if state.rooms.contains_key(&wanted.intent.id)
			|| !state
				.joining
				.get(&wanted.intent.id)
				.is_some_and(|attempt| attempt.epoch == wanted.epoch)
		{
			return Ok(false);
		}
		Ok(self
			.wanted()?
			.get(&wanted.intent.id)
			.is_some_and(|current| current.intent == wanted.intent))
	}
	pub(super) fn clear_attempt(&self, wanted: &Wanted) {
		let mut state = self.shared.borrow_mut();
		if state
			.joining
			.get(&wanted.intent.id)
			.is_some_and(|attempt| attempt.epoch == wanted.epoch)
		{
			state.joining.remove(&wanted.intent.id);
		}
	}
}
