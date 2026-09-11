//! The bytes a room holds for the files posted in it, as the actors members
//! reach them through: one upload capability per admitted file, filled by
//! its poster, and one blob capability per file per hearing member, minted on
//! that member's own connection when the line is told.
use super::{
	answer,
	state::{Shared, State},
};
use glowcap::{Argument, Session};
use rooms_application::{
	files::{Blob, FileError, ReadOutcome, ReadTicket},
	server::rooms::{wire::Encoder, UploadKey},
};
use rooms_glowcap::Value;
use std::future::poll_fn;

/// Draws a room notice for one hearing member, minting each file's blob
/// capability on that member's session.
pub(super) struct Minter<'a> {
	pub state: &'a State,
	pub session: &'a Session,
}

impl rooms_application::server::rooms::wire::DataEncoder for Minter<'_> {
	type Value = Argument;
	fn text(&mut self, value: String) -> Argument {
		Argument::String(value)
	}
	fn integer(&mut self, value: u64) -> Argument {
		Argument::Integer(value as i64)
	}
	fn boolean(&mut self, value: bool) -> Argument {
		Argument::Boolean(value)
	}
}
impl Encoder for Minter<'_> {
	type Error = glowcap::Error;
	fn blob(&mut self, blob: &Blob) -> Result<Argument, glowcap::Error> {
		let shared = self.state.shared();
		let blob = blob.clone();
		let reference = self
			.session
			.spawn_owned(move |verb, args| read(&shared, &blob, verb, args))?;
		Ok(Argument::Reference(reference))
	}
}

/// The blob capability members read a posted file through: `read(offset,
/// maxLen)` answers at most one chunk, and an empty slice at the end. A file
/// the room has dropped breaks `blob-expired` rather than answering empty.
fn read(shared: &Shared, blob: &Blob, verb: &str, args: &[Argument]) -> Result<Argument, String> {
	let values: Vec<Value<'_>> = args.iter().map(Value).collect();
	let mut state = shared.borrow_mut();
	let now = state.now();
	let outcome = state
		.rooms
		.blob_verb(blob, verb, &values, now)
		.map_err(|refusal| refusal.reason())?;
	match outcome {
		ReadOutcome::Ready(bytes) => Ok(Argument::Bytes(bytes.to_vec())),
		ReadOutcome::Waiting(ticket) => {
			let waiting = wait(shared.clone(), ticket);
			answer::later(&state, "read", waiting)
		}
	}
}

/// Wait for the bytes a read asked for, polled by the loop's task; the
/// ticket registers its waker with the store and cancels on drop.
async fn wait(shared: Shared, ticket: ReadTicket) -> Result<Argument, String> {
	poll_fn(|cx| {
		let state = shared.borrow();
		state
			.rooms
			.files()
			.poll_read(&ticket, cx)
			.map(|outcome| outcome.map(|bytes| Argument::Bytes(bytes.to_vec())))
	})
	.await
	.map_err(|error: FileError| error.to_string())
}

/// The upload capability `attach` answers: `write(chunk)` fills the declared
/// size in order, `discard()` gives the room its reservation back.
pub(super) fn upload(shared: Shared, key: UploadKey) -> impl FnMut(&str, &[Argument]) -> Result<Argument, String> {
	move |verb, args| {
		let values: Vec<Value<'_>> = args.iter().map(Value).collect();
		let mut state = shared.borrow_mut();
		let now = state.now();
		state
			.rooms
			.upload_verb(key, verb, &values, now)
			.map_err(|refusal| refusal.reason())?;
		Ok(Argument::Void)
	}
}
