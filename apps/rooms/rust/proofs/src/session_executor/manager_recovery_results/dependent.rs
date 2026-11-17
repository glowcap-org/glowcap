//! A seat held as a live facet over a remote seat, the way a product join
//! leaves it. Its exporter is the session of the seat it forwards to.
use super::{
	super::{requests::coordinate, *},
	rig::{Rig, first_room, room_json},
};
use std::cell::RefCell;

/// The member fixture, except that it keeps the seat it was configured with
/// through that seat's sturdy recipe, because the seat is on another session.
pub(super) struct RemoteSeat {
	pub(super) inner: Box<dyn Content>,
	pub(super) uri: Rc<RefCell<Option<String>>>,
}
impl Content for RemoteSeat {
	fn dependent_requirement(&self, input: Invocation<'_>) -> Result<Requirement> {
		self.inner.dependent_requirement(input)
	}
	fn requirement(&self, input: Invocation<'_>) -> Result<Requirement> {
		self.inner.requirement(input)
	}
	fn references(&self, input: Invocation<'_>) -> Result<Vec<loam::ReferenceRequest>> {
		if input.verb != "configure" {
			return self.inner.references(input);
		}
		let uri = self.uri.borrow().clone();
		Ok(input
			.args
			.iter()
			.enumerate()
			.map(|(index, field)| loam::ReferenceRequest::Save {
				reference: Ref::try_from(field).unwrap(),
				uri: if index == 0 { uri.clone() } else { None },
			})
			.collect())
	}
	fn invoke(&self, call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
		self.inner.invoke(call, input)
	}
}
impl Rig {
	/// Join through the member fixture and keep the returned seat as a live
	/// dependent facet guarded by the joining session. The row then selects that
	/// seat, and its coordinate is returned.
	pub(super) async fn dependent_seat(&self) -> custody::Coordinate {
		let (member, _) = self.member.as_ref().expect("a rig with the member fixture");
		let policy = rooms_glowcap::policy::descriptor().unwrap();
		let permissions: Vec<_> = session::SUPPORTED.iter().map(|permission| permission.key()).collect();
		let terms = policy.value_for_kind(session::KIND, &permissions, &[]).unwrap();
		let (source, _) = self.owner.derive(terms, 1, full_control(terms)).await.unwrap();
		let fields = [self.seat_ref.clone(), member.clone(), member.clone()].map(Argument::Reference);
		self.host.send(member, "configure", &fields).await.unwrap();
		let entrance = coordinate(custody::Role::RoomAccess, 7);
		let inbox = coordinate(custody::Role::RoomInbox, 7);
		for held in [entrance, coordinate(custody::Role::DirectoryAccess, 7), inbox] {
			self.owner.import(held, member.clone(), None).await.unwrap();
		}
		let mut row = room_json(Some(entrance), None, None);
		row["id"] = "joinroom".into();
		row["inbox"] = serde_json::to_value(inbox.key).unwrap();
		let mut intent = self.intent.clone();
		let mut rows = intent.conversations.as_slice().to_vec();
		rows.push(serde_json::from_str(&row.to_string()).unwrap());
		intent.conversations = List::new(rows).unwrap();
		self.owner.replace_workspace(&intent).await.unwrap();
		let base = self.base().await;
		let callback = serde_json::to_string(&inbox.key).unwrap();
		let rest = ["joinroom", "member", callback.as_str()];
		let mut args = vec!["joined".into(), base.into(), "joinRoom".into()];
		args.extend(rest.into_iter().map(Argument::from));
		mutate(&self.host, &source, "command", &args).await.unwrap();
		let status = finished(&self.host, &self.root, "joined", &source).await;
		assert_eq!(status.as_str(), Some("committed"), "{:?}", self.reports.borrow());
		let canonical = serde_json::to_string(&("joined", base, "joinRoom", rest)).unwrap();
		let seat = coordinate(custody::Role::RoomSeat, 9);
		self.owner
			.import_result(
				&source,
				"joined",
				&canonical,
				coordinate(custody::Role::RoomSeat, 1),
				seat,
			)
			.await
			.unwrap();
		let mut intent = self.intent.clone();
		first_room(&mut intent).seat = Some(seat.key.retag());
		self.owner.replace_workspace(&intent).await.unwrap();
		seat
	}
}
