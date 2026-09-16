//! Rejected retained posts complete through the same membership inbox as
//! accepted posts, independently of the future observing line authority.
use super::state::State;
use glowcap::{Argument, Session};
use rooms_application::{
	room::{ArgumentView, receipt},
	server::rooms::{Delivery, MembershipKey, RoomKey},
};
use rooms_glowcap::Value;

pub(super) fn post(
	state: &mut State,
	room: &RoomKey,
	membership: MembershipKey,
	session: &Session,
	args: &[Argument],
	retained: bool,
	apply: impl FnOnce(&mut State, Option<Delivery<u64>>) -> Result<Argument, String>,
) -> Result<Argument, String> {
	let delivery = if retained {
		Some(Delivery {
			caller: state
				.connection_of(session)
				.ok_or("post needs a live calling connection")?,
			request: args
				.get(2)
				.and_then(|arg| Value(arg).integer())
				.and_then(receipt::request)
				.ok_or("post needs a bounded receipt request")?,
		})
	} else {
		None
	};
	let result = apply(state, delivery);
	if result.is_err()
		&& let Some(delivery) = delivery
	{
		state.apply_rooms(state.rooms.reject_delivery(room, membership, delivery));
	}
	result
}
