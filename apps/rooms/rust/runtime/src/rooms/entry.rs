//! A pasted link seats the reader before publishing its conversation row.
//! The normal room worker then consumes the buffered membership and messages.
use super::*;
use rooms_glowcap::client::directory::Directory;

impl<P: Platform> RoomRuntime<P> {
	pub async fn stage_entry(
		&self,
		directory: Directory<P>,
		reference: glowcap::Ref,
		nick: &str,
		room: RoomIntent<'_>,
	) -> Result<(), Error> {
		let intent = intent::Intent::read(room).ok_or_else(|| Error::invalid("invalid room entry"))?;
		let epoch = {
			let mut state = self.shared.borrow_mut();
			if state.entry.is_some() || *self.stop.borrow() {
				return Err(Error::closed("room admission is unavailable"));
			}
			let epoch = state.next_epoch;
			state.next_epoch = epoch
				.checked_add(1)
				.ok_or_else(|| Error::exhausted("room membership epoch exhausted"))?;
			epoch
		};
		let mut joined = worker::joining::subscribe(
			worker::joining::Resolved {
				directory,
				nick: nick.into(),
				reached: join::Reached {
					reference,
					acquired: None,
				},
			},
			self.events.clone(),
			self.notices.clone(),
			self.shared.clone(),
			worker::Wanted { intent, epoch },
		)
		.await?;
		if *self.stop.borrow() || self.shared.borrow().entry.is_some() {
			let left = joined.room.leave().await.map_err(Error::peer);
			return Err(Error::closed("room admission ended while subscribing").retain_result(left));
		}
		joined.committed = false;
		self.shared.borrow_mut().entry = Some(joined);
		Ok(())
	}
	pub fn commit_entry(&self, id: &str) {
		if let Some(entry) = self
			.shared
			.borrow_mut()
			.entry
			.as_mut()
			.filter(|entry| entry.wanted.intent.id == id)
		{
			entry.committed = true;
		}
	}
	pub async fn retire_entry(&self, id: &str) -> Result<(), Error> {
		let entry = {
			let mut state = self.shared.borrow_mut();
			if state.entry.as_ref().is_some_and(|entry| entry.wanted.intent.id == id) {
				state.entry.take()
			} else {
				None
			}
		};
		if let Some(entry) = entry {
			entry.room.leave().await.map_err(Error::peer)?;
		}
		Ok(())
	}
}
