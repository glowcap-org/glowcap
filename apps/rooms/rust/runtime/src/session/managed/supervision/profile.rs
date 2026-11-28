//! Only this membership worker observes its accepted inbox and actual subscription reply.
use super::{Argument, Cell, custody, watch};
use rooms_application::room::carries::{self, Carries};

pub(super) struct Seat {
	key: custody::FieldKey<custody::RoomSeat>,
	pub(super) participant: Cell<bool>,
	pub(super) updates: watch::Sender<bool>,
}
impl Seat {
	pub(super) fn new(key: custody::FieldKey<custody::RoomSeat>) -> Self {
		Self {
			key,
			participant: Cell::new(false),
			updates: watch::channel(false).0,
		}
	}
	pub(super) fn supports(&self, key: custody::FieldKey<custody::RoomSeat>) -> bool {
		self.key == key && self.participant.get() && *self.updates.borrow()
	}
}
pub(super) fn notice(updates: &watch::Sender<bool>, verb: &str, args: &[Argument]) {
	let [from, line, tag, features @ ..] = args else { return };
	if verb != rooms_application::room::inbox::NOTIFY
		|| from.as_str() != Some(rooms_application::room::inbox::ROOM)
		|| line.as_str() != Some("")
		|| tag.as_str() != Some(carries::TAG)
	{
		return;
	}
	let supported = Carries::read(features.iter().map(Argument::as_str)).is_some_and(|facts| facts.profiles);
	updates.send_if_modified(|previous| {
		let changed = *previous != supported;
		*previous = supported;
		changed
	});
}

#[cfg(test)]
mod tests {
	use super::*;
	use core::num::NonZeroU64;

	#[test]
	fn only_the_current_participant_and_a_positive_room_statement_enable_profiles() {
		let slot = NonZeroU64::new(1).unwrap();
		let key = custody::FieldKey::new(slot, slot);
		let replacement = custody::FieldKey::new(slot, NonZeroU64::new(2).unwrap());
		let seat = Seat::new(key);
		let announcement = ["room".into(), "".into(), carries::TAG.into(), "profiles".into()];
		notice(&seat.updates, "notify", &announcement);
		assert!(!seat.supports(key), "observers can receive introductions");
		seat.participant.set(true);
		assert!(seat.supports(key));
		assert!(!seat.supports(replacement));
		notice(&seat.updates, "notify", &announcement[..3]);
		assert!(!seat.supports(key));
		let mut other = announcement;
		other[0] = "other sender".into();
		notice(&seat.updates, "notify", &other);
		assert!(!seat.supports(key));
	}
}
