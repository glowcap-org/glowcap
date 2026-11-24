//! A line's send and the calls on its receipt, as the stand-in answers them
//! (`receipts` holds the receipts the way a session does), with the faults
//! `send-faults` injects into each.
use super::{
	Base, ConversationId, Files, Handback, Outcome, Outgoing, RoomsError, RoomsErrorKind, Sent, append, failure,
	receipts::{self, Receipt, Status},
	rows, unreachable, window,
};
use rooms_application::content::session::effects::Released;

impl Files {
	/// `count` commands of another access, each holding a settled, kept
	/// receipt as any session command does. Each goes through the window's
	/// own reservation, so it evicts what the session evicts and is refused
	/// where the session refuses.
	pub fn crowd(&self, count: usize) -> Result<(), RoomsError> {
		let mut receipts = receipts::read(&self.directory)?;
		for n in 0..count {
			let receipt = Receipt {
				operation: format!("other-{n}"),
				base: 0,
				conversation: "elsewhere".to_owned(),
				text: "x".to_owned(),
				status: Status::Committed,
				kept: true,
				released: false,
			};
			window::reserve(&mut receipts, &self.places()?, receipt)?;
		}
		receipts::write(&self.directory, &receipts)
	}

	/// Take the next injected fault, failing the call for one that fails it.
	fn fault(&self) -> Result<Option<String>, RoomsError> {
		let fault = self.next_fault()?;
		if fault.as_deref() == Some("land") {
			self.land()?;
		}
		match fault.as_deref().and_then(failure) {
			Some(error) => Err(error),
			None => Ok(fault),
		}
	}

	/// The receipt of the same operation, or a refusal when it was sent with
	/// another base or line, the way a session refuses a changed intent.
	fn receipt(receipts: &[Receipt], line: &Outgoing<'_>, base: Base) -> Result<Option<usize>, RoomsError> {
		let Some(index) = receipts.iter().position(|held| held.operation == line.operation) else {
			return Ok(None);
		};
		let held = &receipts[index];
		if held.base != base.0 || held.text != line.text || held.conversation != line.conversation.as_str() {
			return Err(RoomsError::new(
				RoomsErrorKind::Refused,
				"effect witness or intent differs",
			));
		}
		Ok(Some(index))
	}

	/// Commit every parked send, each under its own operation and base.
	fn land(&self) -> Result<(), RoomsError> {
		let path = self.directory.join("late.jsonl");
		let mut receipts = receipts::read(&self.directory)?;
		for parked in rows::<Receipt>(&path)? {
			let conversation = ConversationId::new(parked.conversation.clone());
			self.commit(&Outgoing {
				conversation: &conversation,
				text: &parked.text,
				operation: &parked.operation,
			})?;
			window::reserve(&mut receipts, &self.places()?, parked)?;
		}
		receipts::write(&self.directory, &receipts)?;
		std::fs::write(&path, "").map_err(unreachable)
	}

	fn commit(&self, line: &Outgoing<'_>) -> Result<(), RoomsError> {
		append(
			&self.directory.join("outbox.jsonl"),
			&Sent {
				operation: line.operation.to_owned(),
				conversation: line.conversation.as_str().to_owned(),
				text: line.text.to_owned(),
			},
		)?;
		self.moved(false)
	}

	pub(super) fn send_line(&self, line: &Outgoing<'_>, base: Base) -> Result<Outcome, RoomsError> {
		self.log("send", line, base)?;
		let fault = self.fault()?;
		let mut receipts = receipts::read(&self.directory)?;
		if let Some(index) = Self::receipt(&receipts, line, base)? {
			return Ok(answer(receipts[index].status));
		}
		if fault.as_deref() == Some("conflict") {
			self.moved(true)?;
		}
		let workspace = self.workspace()?;
		if base.0 > workspace.revision {
			return Err(RoomsError::new(
				RoomsErrorKind::Refused,
				"the base is past the revision",
			));
		}
		if base.0 < workspace.fence {
			return Ok(Outcome::Conflict);
		}
		let (status, posts) = match fault.as_deref() {
			Some("lost") => return Err(uncertain("lost the send")),
			Some("late") => {
				let parked = Receipt {
					operation: line.operation.to_owned(),
					base: base.0,
					conversation: line.conversation.as_str().to_owned(),
					text: line.text.to_owned(),
					status: Status::Committed,
					kept: false,
					released: false,
				};
				append(&self.directory.join("late.jsonl"), &parked)?;
				return Err(uncertain("lost the send"));
			}
			Some("unknown") => (Status::Unknown, true),
			Some("vanished") => (Status::Unknown, false),
			Some("pending") => (Status::Pending, true),
			_ => (Status::Committed, true),
		};
		let receipt = Receipt {
			operation: line.operation.to_owned(),
			base: base.0,
			conversation: line.conversation.as_str().to_owned(),
			text: line.text.to_owned(),
			status,
			kept: false,
			released: false,
		};
		window::reserve(&mut receipts, &self.places()?, receipt)?;
		receipts::write(&self.directory, &receipts)?;
		if posts {
			self.commit(line)?;
		}
		match fault.as_deref() {
			Some("uncertain") => Err(uncertain("injected uncertain")),
			_ => Ok(answer(status)),
		}
	}

	pub(super) fn observe_line(&self, line: &Outgoing<'_>, base: Base) -> Result<Outcome, RoomsError> {
		self.log("observe", line, base)?;
		match self.fault()?.as_deref() {
			Some("pending") => return Ok(Outcome::Pending),
			Some("conflict") => return Ok(Outcome::Conflict),
			_ => {}
		}
		let mut receipts = receipts::read(&self.directory)?;
		// tolerant: the session refuses a look at a receipt sent with another
		// base or line, and the bot reads that refusal as nothing applied
		// (`map::observed`), so the stand-in answers what the bot reads.
		let Ok(Some(index)) = Self::receipt(&receipts, line, base) else {
			return Ok(Outcome::Absent);
		};
		if receipts[index].status == Status::Pending {
			receipts[index].status = Status::Committed;
			receipts::write(&self.directory, &receipts)?;
		}
		Ok(answer(receipts[index].status))
	}

	pub(super) fn keep_line(&self, line: &Outgoing<'_>, base: Base) -> Result<(), RoomsError> {
		self.log("keep", line, base)?;
		self.fault()?;
		let mut receipts = receipts::read(&self.directory)?;
		// The session refuses to keep a receipt it no longer holds, with no
		// code, and answers a release of one as released.
		let Some(index) = Self::receipt(&receipts, line, base)? else {
			return Err(RoomsError::new(RoomsErrorKind::Refused, "unknown effect"));
		};
		// A released receipt's result fields are gone, so the session refuses
		// to take its line into the workspace.
		if receipts[index].released {
			return Err(RoomsError::new(RoomsErrorKind::Refused, "the receipt was released"));
		}
		if receipts[index].status != Status::Committed {
			return Err(RoomsError::new(
				RoomsErrorKind::Refused,
				"the command has no committed line",
			));
		}
		if receipts[index].kept {
			return Ok(());
		}
		receipts[index].kept = true;
		receipts::write(&self.directory, &receipts)?;
		self.moved(true)
	}

	pub(super) fn release_line(&self, line: &Outgoing<'_>, base: Base) -> Result<Handback, RoomsError> {
		self.log("release", line, base)?;
		if self.fault()?.as_deref() == Some("executor-running") {
			return Ok(Handback::Running);
		}
		let mut receipts = receipts::read(&self.directory)?;
		let Some(index) = Self::receipt(&receipts, line, base)? else {
			return Ok(Handback::Taken);
		};
		// The session decides: a running receipt stays, an adopted one answers
		// kept and changes nothing, and any other is given up.
		match window::release(&receipts, index)? {
			Released::Running => return Ok(Handback::Running),
			Released::Now => {
				receipts[index].released = true;
				receipts::write(&self.directory, &receipts)?;
			}
			Released::Before | Released::Kept => {}
		}
		Ok(Handback::Taken)
	}
}

fn answer(status: Status) -> Outcome {
	match status {
		Status::Committed => Outcome::Committed,
		Status::Pending => Outcome::Pending,
		Status::Unknown => Outcome::Unknown,
		Status::Unsent => Outcome::Conflict,
	}
}

fn uncertain(why: &str) -> RoomsError {
	RoomsError::new(RoomsErrorKind::Uncertain, format!("the stand-in {why}"))
}
