//! A direct sender receives this delegated line actor. Effects reserve their
//! capacity before dispatch. The shared Line remains the mutation authority.
use crate::Value;
use glowcap::{Argument, Behavior, Ref};
use rooms_application::{
	direct::line as policy,
	room::{
		attachment::Attachment,
		line::{Line, LineChange, Proposal},
		message::LineId,
	},
};

/// A synchronous reservation lets the effect owner bound retained work before
/// a mutation commits. Dropping it after refusal must release that reservation.
/// Commit must accept the change without failing. Asynchronous delivery and
/// archival work remain owned by the resulting event, outside the actor turn.
pub trait Changes {
	type Reservation;
	fn reserve(&mut self, proposal: Proposal<'_, Attachment<Ref>>) -> Result<Self::Reservation, String>;
	fn commit(&mut self, reservation: Self::Reservation, change: LineChange<'_, '_, Attachment<Ref>>);
}

pub fn behavior(
	id: LineId,
	from: String,
	files: Vec<Attachment<Ref>>,
	mut current: impl FnMut() -> bool + 'static,
	mut changes: impl Changes + 'static,
) -> Result<Behavior, String> {
	let mut line = Line::new(id, from, files).map_err(|_| "too many initial direct line files")?;
	Ok(Box::new(move |verb, args| {
		let verb = verb.ok_or("unknown direct line method")?;
		if !current() {
			return Err(rooms_application::failure::Failure {
				code: rooms_application::failure::FailureCode::DirectNotAccepted,
				detail: "that direct conversation is no longer accepted",
			}
			.to_string());
		}
		if args.len() > policy::MAX_ARGUMENTS {
			return Err(policy::Error::Arguments.to_string());
		}
		if verb == rooms_application::protocol_data::WITHDRAW && args.is_empty() && line.is_withdrawn() {
			return Ok(Argument::Void);
		}
		let mut fields = [Value(&Argument::Void); policy::MAX_ARGUMENTS];
		for (field, arg) in fields.iter_mut().zip(args) {
			*field = Value(arg);
		}
		if let Some((reservation, change)) = policy::dispatch_with(&mut line, verb, &fields[..args.len()], |proposal| {
			changes.reserve(proposal)
		})
		.map_err(|e| e.to_string())?
		{
			changes.commit(reservation, change);
		}
		Ok(Argument::Void)
	}))
}
