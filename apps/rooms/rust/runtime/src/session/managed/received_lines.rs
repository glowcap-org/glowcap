//! Received direct lines share callback admission and the session task owner.
//! A displayed line handle requests retirement. The session drains its worker.
use super::{InboxOrigin, Membership, Session, inbox, supervision};
use glowcap::{Behavior, Ref, Result, loam};
use rooms_application::room::message::LineId;
use rooms_glowcap::client::{Deadline, Tasks};
use std::rc::{Rc, Weak};
mod memory;
pub use memory::{LineMemory, LineResize};

pub struct LineReceiver<P: Tasks + Deadline + Clone + 'static>(Weak<super::State<P>>);
impl<P: Tasks + Deadline + Clone + 'static> LineReceiver<P> {
	pub fn receive(
		&self,
		origin: InboxOrigin,
		retained_bytes: usize,
		build: impl FnOnce(LineId, LineMemory) -> core::result::Result<Behavior, String>,
	) -> Result<ReceivedLine<P>> {
		Session {
			state: self
				.0
				.upgrade()
				.ok_or_else(|| loam::refusal("direct line session has closed"))?,
		}
		.receive_line(origin, retained_bytes, build)
	}
}
pub struct ReceivedLine<P: Tasks> {
	id: LineId,
	reference: Ref,
	lifetime: Membership<P>,
}
impl<P: Tasks> ReceivedLine<P> {
	pub fn id(&self) -> LineId {
		self.id
	}
	pub fn reference(&self) -> &Ref {
		&self.reference
	}
	pub fn retire(&self) {
		self.lifetime.request_close();
	}
	pub async fn close(&self) -> Result<()> {
		self.retire();
		self.lifetime.ended().await
	}
}
impl<P: Tasks + Deadline + Clone + 'static> Session<P> {
	pub fn line_receiver(&self) -> LineReceiver<P> {
		LineReceiver(Rc::downgrade(&self.state))
	}
	/// The trusted consumer derives retained_bytes from its behavior's metadata
	/// and files. Admission charges that material before construction. Queue and
	/// actor counts also share the session's callback budget. Refile must reserve
	/// its full resulting metadata through LineMemory before committing. No
	/// payload bytes are assembled. The charge survives actual worker retirement.
	pub fn receive_line(
		&self,
		origin: InboxOrigin,
		retained_bytes: usize,
		build: impl FnOnce(LineId, LineMemory) -> core::result::Result<Behavior, String>,
	) -> Result<ReceivedLine<P>> {
		if self.state.closing.get() || !origin.is_open() {
			return Err(loam::refusal("direct line owner is closed"));
		}
		let id =
			LineId::new(self.state.next_line.get()).ok_or_else(|| loam::refusal("direct line identities exhausted"))?;
		let charge = LineMemory::reserve(
			self.state.line_bytes.clone(),
			retained_bytes,
			size_of::<ReceivedLine<P>>(),
		)?;
		let mut behavior = build(id, charge.clone()).map_err(loam::refusal)?;
		let mut inbox = inbox::open_line(
			&self.state.writer.host,
			self.state.platform.clone(),
			origin,
			self.state.inboxes.clone(),
			Box::new(move |verb, args| {
				let _retained = &charge;
				behavior(verb, args)
			}),
		)?;
		// Zero is the exhausted sentinel refused by LineId::new on the next call.
		self.state.next_line.set(id.get().wrapping_add(1));
		let reference = inbox.reference().clone();
		let lifetime = supervision::spawn(
			&self.state.platform,
			&self.state.lines,
			format!("line-{}", id.get()),
			None,
			move |mut signals| async move {
				signals.ready.send_replace(Some(Ok(())));
				loop {
					if !*signals.stopping.borrow_and_update() {
						let _ = signals.stopping.changed().await;
						continue;
					}
					match inbox.close().await {
						Ok(()) => return Ok(()),
						Err(error) => {
							signals.finished.send_replace(Some(Err(error)));
						}
					}
					let _ = signals.stopping.changed().await;
				}
			},
		);
		Ok(ReceivedLine {
			id,
			reference,
			lifetime,
		})
	}
	pub async fn close_received_lines(&self) -> Result<()> {
		self.state.lines.close_all().await
	}
}
