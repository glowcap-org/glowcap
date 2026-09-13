//! What a live room teaches the checkpoint, committed as facts under the
//! membership's own scope: a requested reconnect that happened, authority the
//! join acquired, the listing id a directory publishes the room under, and
//! the authority changes the room announces later.
use super::*;

impl<P: Platform> RoomWorker<P> {
	/// The facts a fresh join teaches the checkpoint, in the order the join
	/// learned them. Each is committed only while the membership stays current.
	pub(super) async fn commit_joined(
		&self,
		id: &str,
		epoch: u64,
		intent: &intent::Intent,
		acquired: Option<join::Acquired>,
	) -> Result<(), Error> {
		let conversation =
			Id::new(id.to_owned().into()).ok_or_else(|| Error::invalid("room conversation id exceeds its field"))?;
		if intent.reconnect == Some(RoomReconnect::Requested) {
			self.commit(id, epoch, |context| {
				Ok(Fact::RoomReconnect {
					context,
					conversation: conversation.clone(),
					connected: true,
				})
			})
			.await?;
		}
		if let Some(acquired) = acquired {
			self.commit(id, epoch, |context| {
				Ok(Fact::RoomAuthorityAcquired {
					context,
					conversation: conversation.clone(),
					room_link: Bearer::new(acquired.room_link.into())
						.ok_or_else(|| Error::invalid("room link exceeds its field"))?,
					manager_link: Bearer::new(acquired.manager_link.into())
						.ok_or_else(|| Error::invalid("manager link exceeds its field"))?,
				})
			})
			.await?;
		}
		// The listing's id for this room is recorded only when the one the
		// checkpoint holds is gone from the listing. A room the directory
		// still lists under the held id has not moved; and a room joined by
		// name records its id once, from the listing.
		if let Some(found) = self.publication(&intent.directory, &intent.name) {
			let expected = intent.publication.clone();
			let held_still_listed = expected
				.as_deref()
				.is_some_and(|held| self.listed(&intent.directory, held));
			if expected.as_deref() != Some(found.as_str()) && !held_still_listed {
				self.commit(id, epoch, |context| {
					Ok(Fact::RoomPublication {
						context,
						conversation,
						expected: expected.and_then(|value| Field::new(value.into())),
						publication: Field::new(found.into())
							.ok_or_else(|| Error::invalid("room publication id exceeds its field"))?,
					})
				})
				.await?;
			}
		}
		Ok(())
	}
	fn publication(&self, directory: &Id, name: &str) -> Option<String> {
		use rooms_application::session::checkpoint::commands::Facts;
		self.directories
			.read()
			.room_publication(directory.text(), &DocumentText::from(name))?
			.as_str()
			.map(str::to_owned)
	}
	/// Whether the directory lists a room under this publication id.
	fn listed(&self, directory: &Id, id: &str) -> bool {
		let id = DocumentText::from(id);
		let state = self.directories.read();
		state
			.rows()
			.iter()
			.find(|row| row.id() == directory)
			.and_then(|row| row.live())
			.is_some_and(|live| live.view().room(&id).is_some())
	}
	pub(super) async fn commit(
		&self,
		id: &str,
		epoch: u64,
		make: impl FnOnce(RoomContext) -> Result<Fact, Error>,
	) -> Result<(), Error> {
		let (before, scope) = {
			let state = self.shared.borrow();
			let Some(live) = state.rooms.get(id).filter(|live| live.epoch == epoch) else {
				return Ok(());
			};
			(live.intent.clone(), live.scope.clone())
		};
		if let Some(expected) = self.commit_observation(&before, &scope, make).await?
			&& let Some(live) = self
				.shared
				.borrow_mut()
				.rooms
				.get_mut(id)
				.filter(|live| live.epoch == epoch)
		{
			live.intent = expected;
		}
		Ok(())
	}
	pub(super) async fn commit_observation(
		&self,
		before: &intent::Intent,
		scope: &crate::session::commands::FactScope,
		make: impl FnOnce(RoomContext) -> Result<Fact, Error>,
	) -> Result<Option<intent::Intent>, Error> {
		let id = before.id.as_str();
		if !scope.current() {
			return Ok(None);
		}
		let prepared = self.commands.view().read(|state| {
			let checkpoint = state.checkpoint()?;
			let Some(intent) = checkpoint.rooms().find(|intent| intent.id.text().as_str() == Some(id)) else {
				return Ok(None);
			};
			if intent::Intent::read(intent).as_ref() != Some(before) {
				return Ok(None);
			}
			let fact = make(RoomContext::capture(intent))?;
			let next = fact
				.apply(checkpoint, &rooms_glowcap::routes::CheckpointRoutes)
				.map_err(Error::invalid_by)?;
			let expected = next
				.as_ref()
				.unwrap_or(checkpoint)
				.rooms()
				.find(|intent| intent.id.text().as_str() == Some(id))
				.and_then(intent::Intent::read);
			Ok::<_, Error>(Some((fact, expected)))
		})??;
		let Some((fact, expected)) = prepared else {
			return Ok(None);
		};
		// A full fact budget is waited out, never propagated: an `Err` here
		// ends the room worker, and with it the session, over backpressure.
		let admission = match self.commands.admit_scoped_fact(&fact, scope).await {
			Ok(admission) => admission,
			Err(crate::session::commands::AdmissionError::Retired) => return Ok(None),
			Err(error) => return Err(error.into()),
		};
		let reply = admission.send()?;
		let mut changes = self.directories.changes();
		changes.mark_unchanged();
		let mut stopping = self.stopping.clone();
		let wait = reply.wait();
		tokio::pin!(wait);
		loop {
			if *stopping.borrow() {
				scope.retire();
				return Ok(None);
			}
			let current = self.wanted()?.remove(id).map(|wanted| wanted.intent);
			if current.as_ref() != Some(before) && current != expected {
				scope.retire();
				return Ok(None);
			}
			tokio::select! {
				result = &mut wait => {
					result?;
					let current = self.wanted()?.remove(id).map(|wanted| wanted.intent);
					return Ok(if current == expected { expected } else { None });
				}
				_ = changes.changed() => {}
				_ = stopping.changed() => { scope.retire(); return Ok(None); }
			}
		}
	}
}
