//! Shared archive execution. Hosted actors retain weak admission, while the
//! parent owns the serial backend worker and observes its shutdown.
use crate::{Error, platform::Platform};
use glowcap::{Argument, Ref, Resolver, Session};
use rooms_application::archive::{Facet, Filter, Record, index::Page, request::Request};
use rooms_glowcap::{Value, archive as wire};
use std::{
	cell::Cell,
	future::Future,
	rc::{Rc, Weak},
};
use tokio::sync::{mpsc, oneshot, watch};
mod authority;
pub(crate) mod hosting;
use authority::Authority;
use hosting::Permit as FacetPermit;
mod blob_access;
mod blob_host;
pub(crate) use blob_access::checked_bytes;
pub use blob_access::{BlobAccess, UnavailableBlobs};
mod source;
pub use source::{Chunk, Source};
pub(crate) mod ingestion;
mod operation;
mod publications;
pub mod recording;
pub mod session;
mod worker;
use operation::Operation;
pub use worker::{Report, Worker};

/// Storage must return only committed revisions, and own recovery after an
/// interrupted write. This worker never cancels an admitted backend operation
/// during orderly shutdown. Record reads follow preceding puts. A file put's
/// bytes are captured from the caller before the backend sees them, so a slow
/// caller holds only its own put.
///
/// A backend answers with the runtime's classed error: `Error::storage` for
/// its own I/O failures, `Error::refused` for a capability it does not offer.
pub trait Backend {
	/// An independent read executor over committed blobs. File ingestion may
	/// call back into this archive. These reads must not await the write queue.
	fn blob_access(&self) -> impl BlobAccess + use<Self> {
		UnavailableBlobs
	}
	/// Trusted owner operation. Archive facets have no wire erasure verb.
	fn clear(&mut self) -> impl Future<Output = Result<(), Error>> {
		async { Err(Error::refused("archive backend does not support local erasure")) }
	}
	/// Trusted owner erasure for exactly one recorder account. Preserve every
	/// other owner's records, shared blob custody, and the global revision.
	fn clear_source(
		&mut self,
		_source: &rooms_application::text::DocumentText,
	) -> impl Future<Output = Result<(), Error>> {
		async { Err(Error::refused("archive backend does not support scoped erasure")) }
	}
	fn durable_shares(&self) -> bool {
		false
	}
	fn change_share(
		&mut self,
		_command: rooms_application::archive::shares::Command,
	) -> impl Future<Output = Result<rooms_application::archive::shares::Change, Error>> {
		async { Err(Error::refused("archive backend does not retain durable shares")) }
	}
	fn active_shares(&mut self) -> impl Future<Output = Result<Vec<rooms_application::archive::shares::Share>, Error>> {
		async { Err(Error::refused("archive backend does not retain durable shares")) }
	}
	/// File retention support is fixed for this backend owner's lifetime.
	fn retains_blobs(&self) -> bool {
		false
	}
	fn put(&mut self, record: Record) -> impl Future<Output = Result<u64, Error>>;
	fn read(&mut self, filter: &Filter, after: u64, limit: usize) -> impl Future<Output = Result<Page, Error>>;
	fn put_files<S: Source>(&mut self, _record: Record, _sources: &[S]) -> impl Future<Output = Result<u64, Error>> {
		async { Err(Error::refused("archive backend does not retain file bytes")) }
	}
	fn blob_reader(
		&mut self,
		_facet: Facet,
		_digest: String,
	) -> impl Future<Output = Result<rooms_application::archive::blobs::Reader, Error>> {
		async { Err(Error::refused("archive backend does not retain file bytes")) }
	}
	fn read_blob(
		&mut self,
		_reader: rooms_application::archive::blobs::Reader,
		_offset: u64,
		_maximum: usize,
	) -> impl Future<Output = Result<Vec<u8>, Error>> {
		async { Err(Error::refused("archive backend does not retain file bytes")) }
	}
}
pub const REQUEST_LIMIT: usize = 64;
pub const REQUEST_BYTES: usize = 2 * 1024 * 1024;
pub const CALLER_LIMIT: usize = 128;
pub const FACET_BYTES: usize = 2 * 1024 * 1024;
/// File puts whose bytes may be in flight from their callers at once, and the
/// declared bytes they may hold in memory together while they are.
pub const CAPTURE_LIMIT: usize = 32;
pub const CAPTURE_BYTES: usize = 64 * 1024 * 1024;
/// Work retained by this archive at the instant of observation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Usage {
	pub requests: usize,
	pub request_bytes: usize,
	pub captures: usize,
	pub capture_bytes: usize,
	pub facet_bytes: usize,
	pub callers: usize,
}
pub struct Archive<P: Platform>(Rc<State<P>>);
#[derive(Clone)]
pub struct Receiver<P: Platform>(Weak<State<P>>);
struct State<P: Platform> {
	platform: P,
	retains_blobs: bool,
	requests: mpsc::Sender<Pending<P>>,
	stop: watch::Sender<bool>,
	done: watch::Receiver<Option<Report>>,
	admitted: Rc<Cell<(usize, usize)>>,
	captures: Rc<Cell<(usize, usize)>>,
	hosting: hosting::Budget,
}
struct Pending<P: Platform> {
	request: Operation<P>,
	authority: Authority,
	reply: Reply,
	_permit: Permit,
}
enum Reply {
	Remote(Resolver),
	Clear(oneshot::Sender<Result<(), Error>>),
}
struct Permit {
	held: Rc<Cell<(usize, usize)>>,
	bytes: usize,
}
impl Drop for Permit {
	fn drop(&mut self) {
		let (count, bytes) = self.held.get();
		self.held.set((count - 1, bytes - self.bytes));
	}
}
/// One file put's share of the capture budget, held until its bytes are
/// stored or refused.
pub(super) struct FilePermit {
	held: Rc<Cell<(usize, usize)>>,
	bytes: usize,
}
impl Drop for FilePermit {
	fn drop(&mut self) {
		let (count, bytes) = self.held.get();
		self.held.set((count - 1, bytes - self.bytes));
	}
}
impl<P: Platform> Archive<P> {
	pub fn usage(&self) -> Usage {
		let (requests, request_bytes) = self.0.admitted.get();
		let (captures, capture_bytes) = self.0.captures.get();
		Usage {
			requests,
			request_bytes,
			captures,
			capture_bytes,
			facet_bytes: self.0.hosting.bytes(),
			callers: self.0.hosting.callers(),
		}
	}

	pub fn new<B: Backend>(platform: P, backend: B) -> (Self, Worker<B, P>) {
		let (requests, rx) = mpsc::channel(REQUEST_LIMIT);
		let (stop, _) = watch::channel(false);
		let (finished, done) = watch::channel(None);
		let state = Rc::new(State {
			platform,
			retains_blobs: backend.retains_blobs(),
			requests,
			stop,
			done,
			admitted: Rc::new(Cell::new((0, 0))),
			captures: Rc::new(Cell::new((0, 0))),
			hosting: Default::default(),
		});
		(Self(state.clone()), Worker::new(state, rx, finished, backend))
	}
	/// Serialize local erasure after admitted writes. Cancelling this observation
	/// leaves the worker owning the erasure. There is no remote clear authority.
	pub async fn clear(&self) -> Result<(), Error> {
		let request = Operation::Clear;
		let permit = self.0.reserve(&request)?;
		let slot = self
			.0
			.requests
			.try_reserve()
			.map_err(|_| Error::closed("archive worker unavailable"))?;
		let (reply, result) = oneshot::channel();
		slot.send(Pending {
			request,
			authority: Authority::Ordinary,
			reply: Reply::Clear(reply),
			_permit: permit,
		});
		result
			.await
			.map_err(|_| Error::closed("archive worker retired before erasure completed"))?
	}
	pub fn receiver(&self) -> Receiver<P> {
		Receiver(Rc::downgrade(&self.0))
	}
	/// Cancelling this observation leaves the owned worker draining. Close the
	/// archive before its backend/Host/transport owners. No Session is closed here.
	pub async fn close(&self) -> Result<Report, Error> {
		self.0.stop.send_replace(true);
		let mut done = self.0.done.clone();
		loop {
			if let Some(report) = done.borrow().clone() {
				return Ok(report);
			}
			done.changed()
				.await
				.map_err(|_| Error::closed("archive worker retired without observing completion"))?;
		}
	}
}
impl<P: Platform> Drop for Archive<P> {
	fn drop(&mut self) {
		self.0.stop.send_replace(true);
	}
}
impl<P: Platform> State<P> {
	fn live(&self) -> Result<(), Error> {
		if *self.stop.borrow() || self.done.borrow().is_some() || self.done.has_changed().is_err() {
			Err(Error::closed("archive owner has ended"))
		} else {
			Ok(())
		}
	}
	fn reserve(&self, request: &Operation<P>) -> Result<Permit, Error> {
		self.live()?;
		let bytes = request.heap_bytes() + core::mem::size_of::<Pending<P>>();
		let (count, held) = self.admitted.get();
		if count == REQUEST_LIMIT || bytes > REQUEST_BYTES.saturating_sub(held) {
			return Err(Error::busy("archive request backlog is full"));
		}
		self.admitted.set((count + 1, held + bytes));
		Ok(Permit {
			held: self.admitted.clone(),
			bytes,
		})
	}
	/// Admit a file put's declared bytes into the capture budget. Refused
	/// synchronously, so a caller learns at once that its files will not be
	/// taken rather than after its bytes were.
	fn reserve_files(&self, mut sizes: impl Iterator<Item = usize>) -> Result<FilePermit, Error> {
		let bytes = sizes
			.try_fold(0usize, |total, size| total.checked_add(size))
			.ok_or_else(|| Error::invalid("archive file put exceeds the addressable capture size"))?;
		let (count, held) = self.captures.get();
		if count == CAPTURE_LIMIT || bytes > CAPTURE_BYTES.saturating_sub(held) {
			return Err(Error::busy("archive file capture budget is full"));
		}
		self.captures.set((count + 1, held + bytes));
		Ok(FilePermit {
			held: self.captures.clone(),
			bytes,
		})
	}
	fn facet_permit(&self, facet: &Facet) -> Result<FacetPermit, Error> {
		let bytes =
			core::mem::size_of::<(Facet, Receiver<P>, FacetPermit, Authority)>() + facet.scope().retained_bytes();
		self.hosting.retain(bytes)
	}
}
impl<P: Platform> Receiver<P> {
	/// Root occurrences are created by the trusted parent. Descendants all use
	/// the same issuer and backend admission. Cloning Receiver creates neither.
	pub fn spawn(&self, session: &Session, facet: Facet) -> Result<Ref, Error> {
		self.spawn_authorized(session, facet, Authority::Ordinary)
	}
	fn spawn_authorized(&self, session: &Session, facet: Facet, authority: Authority) -> Result<Ref, Error> {
		authority.check()?;
		let state = self
			.0
			.upgrade()
			.ok_or_else(|| Error::closed("archive owner has ended"))?;
		state.live()?;
		let permit = state.facet_permit(&facet)?;
		let receiver = self.clone();
		Ok(session.spawn_owned(move |verb, args| {
			let _held = &permit;
			receiver
				.receive(&facet, &authority, verb, args)
				.map_err(Error::into_refusal)
		})?)
	}
	fn receive(
		&self,
		facet: &Facet,
		authority: &Authority,
		verb: Option<&str>,
		args: &[Argument],
	) -> Result<Argument, Error> {
		let verb = verb.ok_or_else(|| Error::invalid("unknown archive method"))?;
		let state = self
			.0
			.upgrade()
			.ok_or_else(|| Error::closed("archive owner has ended"))?;
		state.live()?;
		authority.check()?;
		use rooms_application::archive::shares::protocol as shares;
		if matches!(verb, shares::ISSUE | shares::REVOKE | shares::LIST) {
			if !authority.issuer() {
				return Err(Error::refused("this archive cannot mint a durable share"));
			}
			if args.len() > 3 {
				return Err(Error::invalid("invalid archive share argument count"));
			}
			let empty = Argument::Void;
			let mut views = [Value(&empty); 3];
			for (view, argument) in views.iter_mut().zip(args) {
				*view = Value(argument);
			}
			let request = shares::Request::read(verb, &views[..args.len()]).map_err(Error::invalid_by)?;
			return self.enqueue(&state, authority, Operation::Shares(request));
		}
		use rooms_application::archive::blobs::admission;
		if matches!(verb, admission::PUT_FILES | admission::ATTACHMENT | admission::BLOB) {
			return self.receive_blob(&state, facet, authority, verb, args);
		}
		if args.len() > 3 {
			return Err(Error::invalid("invalid archive argument count"));
		}
		let empty = Argument::Void;
		let mut views = [Value(&empty); 3];
		for (view, argument) in views.iter_mut().zip(args) {
			*view = Value(argument);
		}
		let request = facet.admit(verb, &views[..args.len()]).map_err(Error::invalid_by)?;
		match request {
			Request::Empty(page) => wire::page_row(&page, &Filter::default(), page.next, 1).map_err(Error::invalid_by),
			Request::Narrow(narrowed) => {
				let session = glowcap::current_session()?
					.ok_or_else(|| Error::invalid("archive narrow needs a caller session"))?;
				let reference = state.hosting.mint(&session, hosting::Kind::Facet, || {
					self.spawn_authorized(&session, narrowed, authority.descendant())
				})?;
				Ok(reference.into())
			}
			request => self.enqueue(&state, authority, Operation::Record(request)),
		}
	}
}
