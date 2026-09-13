//! An outgoing effect reserves its eventual event before contacting the peer.
use super::*;
pub struct OutgoingEvent<P: Platform> {
	owner: Weak<State<P>>,
	context: AcceptedDirect,
	from: String,
	reservation: Reservation,
	pub id: LineId,
}
impl<P: Platform> EventReceiver<P> {
	pub fn generation(&self) -> Result<[u8; 16], Error> {
		Ok(self.0.upgrade().ok_or_else(owner_ended)?.generation)
	}
	pub fn outgoing(
		&self,
		context: &AcceptedDirect,
		id: Option<LineId>,
		text: &str,
		descriptions: impl Iterator<Item = usize>,
	) -> Result<OutgoingEvent<P>, Error> {
		let owner = self.0.upgrade().ok_or_else(owner_ended)?;
		let from = context.nickname()?;
		let bytes = descriptions.fold(text.len().saturating_add(from.len()), |bytes, description| {
			bytes
				.saturating_add(description)
				.saturating_add(core::mem::size_of::<FileView>())
		});
		let reservation = owner.reserve(context, bytes)?;
		let id = match id {
			Some(id) => id,
			None => {
				let id = LineId::new(owner.next.get())
					.ok_or_else(|| Error::exhausted("direct line identifiers are exhausted"))?;
				owner.next.set(id.get() + 1);
				id
			}
		};
		Ok(OutgoingEvent {
			owner: Rc::downgrade(&owner),
			context: context.clone(),
			from,
			reservation,
			id,
		})
	}
}
impl<P: Platform> OutgoingEvent<P> {
	pub fn commit(
		self,
		text: String,
		kind: ChangeKind,
		previews: rooms_application::open_graph::Selection,
		files: Vec<FileView>,
		editable: bool,
	) -> Result<(), Error> {
		let owner = self.owner.upgrade().ok_or_else(owner_ended)?;
		if !self.context.current() || owner.tx.borrow().as_ref().is_none_or(mpsc::Sender::is_closed) {
			return Err(Error::closed("the outgoing direct event has retired"));
		}
		let content = Content::Line(Line {
			line: self.id,
			text,
			kind,
			previews,
			files: Vec::new(),
		});
		let recording = owner.record(
			&self.context,
			&content,
			files.clone(),
			self.reservation.at,
			Some(&self.from),
		);
		self.reservation.slot.send(Event {
			generation: self.reservation.generation,
			at: self.reservation.at,
			context: self.context,
			direction: Direction::Outgoing,
			from: self.from,
			editable,
			content,
			files,
			recording,
			_permit: self.reservation.permit,
		});
		Ok(())
	}
}
