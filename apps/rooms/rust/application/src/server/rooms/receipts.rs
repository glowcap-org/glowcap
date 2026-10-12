//! Receipt selection happens during the ordinary broadcast traversal. Calling
//! connection affects delivery only. Possession still authorizes a delegated post.
use super::{Effects, MembershipKey, Notice, RoomKey, Rooms};
use crate::room::message::ChangeKind;

#[derive(Clone, Copy)]
pub struct Delivery<C> {
	pub caller: C,
	pub request: u64,
}
pub(super) struct Retained {
	pub membership: MembershipKey,
	pub request: u64,
	pub normalized: bool,
}
impl<C: Copy + Ord, R: Clone> Rooms<C, R> {
	/// Add correlation to exactly the posting subscriber's existing notification.
	/// The operation string is bounded by OperationId and lives only with that
	/// one queued event. Everyone else shares the ordinary line representation.
	pub fn correlate(
		&self,
		room: &RoomKey,
		membership: MembershipKey,
		caller: C,
		operation: &str,
		mutation: &mut super::Mutation<C, R>,
	) where
		R: PartialEq,
	{
		let Some(member) = self.rooms.get(room).and_then(|room| room.member(membership)) else {
			return;
		};
		if member.connection != caller || !crate::room::correlation::valid(operation) {
			return;
		}
		for tell in &mut mutation.effects.tells {
			if tell.connection != caller || tell.inbox != member.inbox {
				continue;
			}
			if let Notice::Line { line, marker, files } = &mut tell.notice {
				tell.notice = Notice::CorrelatedLine {
					operation: operation.into(),
					line: line.clone(),
					marker: *marker,
					files: core::mem::take(files),
				};
				break;
			}
		}
	}
	/// A refusal completes only the calling subscriber's retained request.
	/// Delegated callers cannot discard another connection's pending text.
	pub fn reject_delivery(&self, room: &RoomKey, membership: MembershipKey, delivery: Delivery<C>) -> Effects<C, R> {
		let mut effects = Effects::default();
		if let Some(member) = self.rooms.get(room).and_then(|room| room.member(membership))
			&& member.connection == delivery.caller
		{
			effects.tell(
				member.connection,
				member.inbox.clone(),
				Notice::ReceiptRejected(delivery.request),
			);
		}
		effects
	}
	pub(super) fn broadcast_line(
		&self,
		room: &RoomKey,
		effects: &mut Effects<C, R>,
		notice: Notice,
		receipt: Option<Retained>,
	) {
		let Some(room) = self.rooms.get(room) else {
			return;
		};
		for member in &room.members {
			let told = match (&notice, &receipt) {
				(
					Notice::Line {
						line,
						marker: Some((ChangeKind::Said, id)),
						files,
					},
					Some(receipt),
				) if member.key == receipt.membership => Notice::Receipt {
					request: receipt.request,
					line: line.clone(),
					id: *id,
					normalized: receipt.normalized,
					files: files.clone(),
				},
				_ => notice.clone(),
			};
			effects.tell(member.connection, member.inbox.clone(), told);
		}
	}
}
