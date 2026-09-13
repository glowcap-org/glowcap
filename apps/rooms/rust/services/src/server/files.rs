//! The bytes a room holds for the files posted in it, as the actors members
//! reach them through: one upload capability per admitted file, filled by
//! its poster, and one blob capability per file per hearing member, minted on
//! that member's own connection when the line is told.
use super::{
	answer, history, lines, seat,
	state::{Shared, State},
};
use glowcap::{Argument, Session};
use rooms_application::{
	failure::FailureCode,
	files::{Blob, FileError, ReadOutcome, ReadTicket},
	server::rooms::{MembershipKey, RoomKey, UploadKey, wire::Encoder},
};
use rooms_glowcap::Value;
use std::{cell::Cell, future::poll_fn, rc::Rc};

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
			answer::later(&state, rooms_application::protocol_data::READ, waiting)
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

const POST_FILES: &str = rooms_application::protocol_data::POST_FILES;
const ATTACH: &str = rooms_application::protocol_data::ATTACH;

/// The files facet `subscribe` hands a participant, beside the seat: the
/// authority to stage files against this room's storage and publish them
/// as one line. Handed over only where the room can hold bytes, so a client
/// that was answered null here draws no attach control at all, and a bridge
/// to a service with no way to carry a file never answers with one. Holding
/// it is the whole of the authority: a member can pass it to a helper that
/// posts on their behalf without handing over the seat.
pub(super) fn facet(
	shared: Shared,
	room: RoomKey,
	membership: Rc<Cell<Option<MembershipKey>>>,
) -> impl FnMut(&str, &[Argument]) -> Result<Argument, String> {
	move |verb, args| {
		let (membership, session) = seat::admitted(&membership, "room files facet", verb, args)?;
		let mut state = shared.borrow_mut();
		let text = |at: usize| args.get(at).and_then(Argument::as_str);
		match verb {
			POST_FILES => {
				let (Some(caption), 1) = (text(0), args.len()) else {
					return Err(format!(
						"{}: postFiles needs one caption",
						FailureCode::BadAttachment.wire()
					));
				};
				let key = Rc::new(Cell::new(None));
				let actor = session
					.spawn_owned(lines::line(shared.clone(), key.clone()))
					.map_err(|e| e.to_string())?;
				let now = state.now();
				let line = history::mutate(&mut state, |rooms| {
					rooms.post_files(&room, membership, caption, State::wall_clock(), now)
				})?;
				key.set(Some(line));
				Ok(Argument::Reference(actor))
			}
			rooms_application::open_graph::ROOM_POST_FILES_VERB => {
				let (Some(caption), Some(encoded), 2) = (text(0), text(1), args.len()) else {
					return Err("postFilesWithPreviews needs a caption and one preview selection".into());
				};
				let previews = rooms_application::open_graph::Selection::decode(caption, encoded)
					.map_err(|error| error.to_string())?;
				let key = Rc::new(Cell::new(None));
				let actor = session
					.spawn_owned(lines::line(shared.clone(), key.clone()))
					.map_err(|e| e.to_string())?;
				let now = state.now();
				let line = history::mutate(&mut state, |rooms| {
					rooms.post_files_with_previews(&room, membership, caption, previews, State::wall_clock(), now)
				})?;
				key.set(Some(line));
				Ok(Argument::Reference(actor))
			}
			ATTACH => {
				let description =
					rooms_application::server::rooms::wire::attachment(args.len(), |at| args.get(at).map(Value))
						.map_err(seat::refusal)?;
				let now = state.now();
				let key = state
					.rooms
					.attach(&room, membership, description, now)
					.map_err(seat::refusal)?;
				state.upload_admitted.notify_one();
				let upload = session
					.spawn_owned(upload(shared.clone(), key))
					.map_err(|e| e.to_string())?;
				Ok(Argument::Reference(upload))
			}
			_ => Err(format!("room files facet has no method {verb}")),
		}
	}
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
