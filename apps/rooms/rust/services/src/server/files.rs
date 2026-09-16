//! The bytes a room holds for the files posted in it, as the actors members
//! reach them through: one upload capability per admitted file, filled by
//! its poster, and one read capability per live file and receiving connection,
//! reused whenever a notification names that file.
use super::{
	answer, history, lines, seat,
	state::{Shared, State},
};
use glowcap::{Argument, Ref, Session};
use rooms_application::{
	failure::FailureCode,
	files::{Blob, FileError, FileStore, ReadOutcome, ReadTicket},
	server::rooms::{MembershipKey, RoomKey, UploadKey, wire::Encoder},
};
use rooms_glowcap::Value;
use std::{
	cell::{Cell, RefCell},
	collections::BTreeMap,
	future::poll_fn,
	rc::Rc,
};

/// One connection retains one reader identity per file. Reclaiming retired
/// identities before insertion bounds this inventory by the store's peak live
/// file count; closing the connection drops all its local roots.
#[derive(Default)]
pub(super) struct Capabilities {
	held: RefCell<BTreeMap<u64, (Blob, Ref)>>,
	retirements: Cell<u64>,
}
impl Capabilities {
	fn reader(
		&self,
		store: &FileStore,
		blob: &Blob,
		mint: impl FnOnce() -> Result<Ref, glowcap::Error>,
	) -> Result<Ref, glowcap::Error> {
		let mut held = self.held.borrow_mut();
		let id = store.blob_id(blob).expect("the server's own file store");
		if let Some((_, reference)) = held.get(&id) {
			return Ok(reference.clone());
		}
		// New uploads and repeated refiles are ordered lookups. A storage
		// retirement triggers one sweep before this inventory next grows.
		if self.retirements.get() != store.retirements() {
			held.retain(|_, (blob, _)| store.contains(blob));
			self.retirements.set(store.retirements());
		}
		// Lines can still carry expired files after pruning. Reissuing them
		// preserves their refusal behavior without growing retained identities.
		if !store.contains(blob) {
			return mint();
		}
		let reference = mint()?;
		held.insert(id, (blob.clone(), reference.clone()));
		Ok(reference)
	}
}
fn reader(state: &State, session: &Session, blob: &Blob) -> Result<Ref, glowcap::Error> {
	let shared = Rc::downgrade(&state.shared());
	let blob = blob.clone();
	session.spawn_owned(move |verb, args| {
		let shared = shared.upgrade().ok_or("room file owner is closed")?;
		read(&shared, &blob, verb, args)
	})
}

/// Draws a room notice using the receiving connection's file capabilities.
pub(super) struct Minter<'a> {
	pub state: &'a State,
	pub session: &'a Session,
	capabilities: Option<&'a Capabilities>,
}
impl<'a> Minter<'a> {
	pub fn new(state: &'a State, session: &'a Session) -> Self {
		Self {
			state,
			session,
			capabilities: state.file_capabilities(session),
		}
	}
	pub fn connected(state: &'a State, session: &'a Session, capabilities: &'a Capabilities) -> Self {
		Self {
			state,
			session,
			capabilities: Some(capabilities),
		}
	}
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
		let reference = match self.capabilities {
			Some(held) => held.reader(self.state.rooms.files(), blob, || {
				reader(self.state, self.session, blob)
			})?,
			None => reader(self.state, self.session, blob)?,
		};
		Ok(Argument::Reference(reference))
	}
}

#[cfg(test)]
mod tests;

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
			POST_FILES
			| rooms_application::open_graph::ROOM_POST_FILES_VERB
			| rooms_application::room::receipt::POST_FILES => {
				let retained = verb == rooms_application::room::receipt::POST_FILES;
				super::receipts::post(
					&mut state,
					&room,
					membership,
					&session,
					args,
					retained,
					|state, delivery| {
						let previews = verb != POST_FILES;
						let expected = if retained {
							3
						} else if previews {
							2
						} else {
							1
						};
						let caption = text(0).filter(|_| args.len() == expected).ok_or_else(|| {
							format!(
								"{}: postFiles needs a caption and the selected delivery fields",
								FailureCode::BadAttachment.wire()
							)
						})?;
						let previews = if previews && !(retained && matches!(args[1], Argument::Boolean(false))) {
							rooms_application::open_graph::Selection::decode(
								caption,
								text(1).ok_or("postFiles needs one preview selection")?,
							)
							.map_err(|e| e.to_string())?
						} else {
							Default::default()
						};
						let key = Rc::new(Cell::new(None));
						let actor = session
							.spawn_owned(lines::line(shared.clone(), key.clone()))
							.map_err(|e| e.to_string())?;
						let now = state.now();
						let line = history::mutate(state, |rooms| {
							rooms.post_files_delivered(
								&room,
								membership,
								caption,
								previews,
								State::wall_clock(),
								now,
								delivery,
							)
						})?;
						key.set(Some(line));
						Ok(Argument::Reference(actor))
					},
				)
			}
			ATTACH | rooms_application::room::receipt::ATTACH => {
				let description =
					rooms_application::server::rooms::wire::attachment(args.len(), |at| args.get(at).map(Value))
						.map_err(seat::refusal)?;
				let now = state.now();
				let key = state
					.rooms
					.attach(&room, membership, description, now)
					.map_err(seat::refusal)?;
				state.upload_admitted.notify_one();
				let minted = (|| {
					let upload = session
						.spawn_owned(upload(shared.clone(), key))
						.map_err(|e| e.to_string())?;
					if verb == rooms_application::room::receipt::ATTACH {
						let blob = state.rooms.upload_blob(key).expect("just admitted upload");
						let blob = Minter::new(&state, &session).blob(&blob).map_err(|e| e.to_string())?;
						Ok(Argument::List(vec![upload.into(), blob]))
					} else {
						Ok(Argument::Reference(upload))
					}
				})();
				minted.map_err(|primary: String| match state.rooms.cancel_upload(key, now) {
					Ok(()) => primary,
					Err(cleanup) => format!("{primary}; upload cleanup failed: {}", cleanup.reason()),
				})
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
