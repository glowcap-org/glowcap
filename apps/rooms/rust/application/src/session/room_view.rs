//! Presence and room facts reduce into one bounded session view. Both native
//! and browser-hosted sessions project this state; widgets never replay it.
use super::snapshot::{
	views::{Bridge, Member, RoomView, Seat, SeatPhase},
	Nullable, Presence as FieldPresence, SafeInteger, Text,
};
use crate::room::inbox::metadata::{Facts, Presence};
use alloc::vec::Vec;

pub fn apply<T: AsRef<str>>(view: &mut RoomView, presence: Option<&Presence<T>>, facts: Option<&Facts<T>>) {
	if let Some(presence) = presence {
		let rows = &mut view.members.0;
		match presence {
			Presence::Roster { names } => {
				view.members_more = Some(false);
				// Mark known live names first, so inserting a new name cannot
				// evict a later roster entry and forget its away state.
				for (name, member) in rows.iter_mut() {
					member.online = names
						.iter()
						.any(|candidate| name.text().as_str() == Some(candidate.as_ref()));
					member.seat = None;
				}
				for name in names {
					if let Some(index) = slot(rows, name.as_ref(), &mut view.members_more) {
						rows[index].1.online = true;
					}
				}
			}
			Presence::Join { name } | Presence::Leave { name } => {
				if let Some(index) = slot(rows, name.as_ref(), &mut view.members_more) {
					rows[index].1 = Member {
						online: matches!(presence, Presence::Join { .. }),
						away: empty(),
						seat: None,
					};
				}
			}
			Presence::Away { name, reason } => {
				if let (Some(index), Some(away)) = (find(rows, name.as_ref()), Text::new(reason.as_ref().into())) {
					rows[index].1.away = away;
				}
			}
			Presence::Seat(seat) => {
				if let (Some(index), Some(seat)) = (find(rows, seat.name.as_ref()), seat_view(seat)) {
					rows[index].1.seat = Some(seat);
				}
			}
		}
	}
	if let Some(facts) = facts {
		if let Some(topic) = facts.topic.as_ref().and_then(|topic| Text::new(topic.as_ref().into())) {
			view.topic = Nullable::Value(topic);
		}
		if let Some(bytes) = facts.line_bytes.and_then(SafeInteger::new) {
			view.line_bytes = Nullable::Value(bytes);
		}
		if let Some(bridge) = facts.bridge.as_ref().and_then(|bridge| bridge_view(bridge)) {
			view.bridge = FieldPresence::Value(bridge);
		}
	}
}
type Rows = Vec<(Text<32, true>, Member)>;
fn empty() -> Text<120> {
	Text::new("".into()).expect("empty standing fits")
}
fn find(rows: &Rows, name: &str) -> Option<usize> {
	rows.iter().position(|(held, _)| held.text().as_str() == Some(name))
}
fn slot(rows: &mut Rows, name: &str, more: &mut Option<bool>) -> Option<usize> {
	if let Some(index) = find(rows, name) {
		return Some(index);
	}
	let name = Text::new(name.into())?;
	if rows.len() == super::snapshot::views::MAX_MEMBERS {
		if let Some(index) = rows.iter().position(|(_, member)| !member.online) {
			rows.remove(index);
		} else {
			*more = Some(true);
			return None;
		}
	}
	rows.push((
		name,
		Member {
			online: false,
			away: empty(),
			seat: None,
		},
	));
	Some(rows.len() - 1)
}
fn seat_view<T: AsRef<str>>(seat: &crate::room::inbox::metadata::Seat<T>) -> Option<Seat> {
	use serde::Deserialize;
	let state = SeatPhase::deserialize(serde::de::value::StrDeserializer::<serde::de::value::Error>::new(
		seat.state.as_ref(),
	))
	.ok()?;
	Some(Seat {
		network: Text::new(seat.network.as_ref().into())?,
		state,
		nick: Text::new(seat.nick.as_ref().into())?,
		badge: Text::new(seat.badge.as_ref().into())?,
		said: Text::new(seat.said.as_ref().into())?,
	})
}
fn bridge_view<T: AsRef<str>>(bridge: &crate::room::inbox::metadata::Bridge<T>) -> Option<Bridge> {
	Some(Bridge {
		prefix: Text::new(bridge.prefix.as_ref().into())?,
		badge: Text::new(bridge.badge.as_ref().into())?,
		said: Text::new(bridge.said.as_ref().into())?,
		scope: Text::new(bridge.scope.as_ref().into())?,
	})
}
