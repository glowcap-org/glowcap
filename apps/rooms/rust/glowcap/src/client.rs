//! Shared client execution over the existing Rust Host binding. The platform
//! supplies deadline scheduling; application reply policy lives in Rooms core.
use glowcap::{Argument, Ref, Session};
use rooms_application::{
	failure::{Failure, Retry},
	room::authority::{self, Refusal},
};
use std::{
	future::{Future, IntoFuture},
	rc::Rc,
};
pub mod archive;
pub mod direct;
pub mod directory;
pub mod files;
pub mod invitation;
pub mod manager;
pub mod posted_line;
pub mod room;
pub mod session;
pub mod sources;
pub mod stewardship;

/// Ending a deadline drops the pending observation. The binding retains and
/// retires any protocol work and releases late projected reply occurrences.
pub trait Deadline {
	fn within<T>(&self, milliseconds: u64, work: impl Future<Output = T>) -> impl Future<Output = Option<T>>;
}
/// Platform task custody. Dropping Task cancels its future and releases all
/// resources held by that observation; detached background work is not allowed.
pub trait Tasks {
	type Task;
	fn spawn(&self, work: impl Future<Output = ()> + 'static) -> Self::Task;
}
/// Cryptographic randomness is a platform effect, independent of scheduling.
pub trait Entropy {
	fn invitation_receipt(
		&self,
	) -> Result<rooms_application::room::invitation::Receipt, rooms_application::room::invitation::Error>;
}
#[derive(Clone, Debug)]
pub enum Error {
	ArchiveShare(rooms_application::archive::shares::Error),
	Archive(rooms_application::archive::Error),
	Inbox(rooms_application::direct::publication::Error),
	Sources(rooms_application::files::sources::Error),
	Direct(rooms_application::direct::Error),
	Signaling(rooms_application::signaling::Error),
	Introduction(rooms_application::directory::introduction::Error),
	Binding(Box<glowcap::Error>),
	Timeout(&'static str),
	Reply(Refusal),
	Custody(rooms_application::room::stewardship::Error),
	Membership(rooms_application::room::membership::Error),
	History(rooms_application::room::history::Error),
	Transfer(rooms_application::files::transfer::Error),
	Invitation(rooms_application::room::invitation::Error),
	Query(rooms_application::room::queries::Error),
	Bridge(rooms_application::bridge::Error),
	Directory(rooms_application::directory::Error),
	Registration(rooms_application::directory::registration::Error),
}
impl Error {
	/// A protocol refusal leaves the selected capability usable; transport loss
	/// and a missed deadline mean this client no longer has a proved live peer.
	pub fn connection_failed(&self) -> bool {
		match self {
			Self::Binding(error) => binding_kind_connection_failed(error.kind()),
			Self::Timeout(_) => true,
			_ => false,
		}
	}
	/// Preserve a peer's canonical Rooms failure code when it supplied one.
	/// Untyped application refusals may depend on either a different request or
	/// changed peer state; transport loss always needs the connection to change.
	pub fn retry(&self) -> Retry {
		if let Self::Binding(error) = self {
			return binding_retry(error);
		}
		if matches!(self, Self::Timeout(_)) {
			return Retry::AfterStateChange;
		}
		let reason = self.to_string();
		coded_retry(&reason).unwrap_or(Retry::AfterRequestOrStateChange)
	}
}

/// Retry classification for the shared binding error carried by client and
/// runtime failures. A broken promise belongs to the remote application; the
/// remaining kinds distinguish a definite local request defect from binding or
/// connection state. A frame-size failure is direction-dependent, so either
/// the request or the peer state may have to change.
pub fn binding_retry(error: &glowcap::Error) -> Retry {
	if error.is_publication_not_found() {
		return Retry::AfterRequestChange;
	}
	binding_kind_retry(error.kind(), error.message())
}

fn binding_kind_connection_failed(kind: glowcap::ErrorKind) -> bool {
	matches!(
		kind,
		glowcap::ErrorKind::Closed | glowcap::ErrorKind::Io | glowcap::ErrorKind::TimedOut
	)
}

fn binding_kind_retry(kind: glowcap::ErrorKind, message: Option<&str>) -> Retry {
	use glowcap::ErrorKind;
	match kind {
		ErrorKind::Broken => message
			.and_then(coded_retry)
			.unwrap_or(Retry::AfterRequestOrStateChange),
		ErrorKind::NullPointer
		| ErrorKind::InvalidArgument
		| ErrorKind::UnsupportedValue
		| ErrorKind::BufferTooSmall => Retry::AfterRequestChange,
		ErrorKind::FrameTooLarge | ErrorKind::NotFound => Retry::AfterRequestOrStateChange,
		_ => Retry::AfterStateChange,
	}
}

fn coded_retry(reason: &str) -> Option<Retry> {
	Failure::parse(reason).map(|failure| failure.code.definition().retry)
}
impl From<rooms_application::archive::shares::Error> for Error {
	fn from(error: rooms_application::archive::shares::Error) -> Self {
		Self::ArchiveShare(error)
	}
}
impl From<rooms_application::archive::Error> for Error {
	fn from(error: rooms_application::archive::Error) -> Self {
		Self::Archive(error)
	}
}
impl From<rooms_application::files::sources::Error> for Error {
	fn from(error: rooms_application::files::sources::Error) -> Self {
		Self::Sources(error)
	}
}
impl From<rooms_application::direct::publication::Error> for Error {
	fn from(error: rooms_application::direct::publication::Error) -> Self {
		Self::Inbox(error)
	}
}
impl From<rooms_application::direct::Error> for Error {
	fn from(error: rooms_application::direct::Error) -> Self {
		Self::Direct(error)
	}
}
impl From<rooms_application::signaling::Error> for Error {
	fn from(error: rooms_application::signaling::Error) -> Self {
		Self::Signaling(error)
	}
}
impl From<rooms_application::directory::introduction::Error> for Error {
	fn from(error: rooms_application::directory::introduction::Error) -> Self {
		Self::Introduction(error)
	}
}
impl From<rooms_application::directory::registration::Error> for Error {
	fn from(error: rooms_application::directory::registration::Error) -> Self {
		Self::Registration(error)
	}
}
impl From<rooms_application::directory::Error> for Error {
	fn from(error: rooms_application::directory::Error) -> Self {
		Self::Directory(error)
	}
}
impl From<rooms_application::bridge::Error> for Error {
	fn from(error: rooms_application::bridge::Error) -> Self {
		Self::Bridge(error)
	}
}
impl From<rooms_application::room::invitation::Error> for Error {
	fn from(error: rooms_application::room::invitation::Error) -> Self {
		Self::Invitation(error)
	}
}
impl From<rooms_application::room::queries::Error> for Error {
	fn from(error: rooms_application::room::queries::Error) -> Self {
		Self::Query(error)
	}
}
impl From<rooms_application::files::transfer::Error> for Error {
	fn from(error: rooms_application::files::transfer::Error) -> Self {
		Self::Transfer(error)
	}
}
impl From<rooms_application::room::history::Error> for Error {
	fn from(error: rooms_application::room::history::Error) -> Self {
		Self::History(error)
	}
}
impl From<rooms_application::room::membership::Error> for Error {
	fn from(error: rooms_application::room::membership::Error) -> Self {
		Self::Membership(error)
	}
}
impl From<rooms_application::room::stewardship::Error> for Error {
	fn from(error: rooms_application::room::stewardship::Error) -> Self {
		Self::Custody(error)
	}
}
impl From<Refusal> for Error {
	fn from(error: Refusal) -> Self {
		Self::Reply(error)
	}
}
impl From<glowcap::Error> for Error {
	fn from(error: glowcap::Error) -> Self {
		Self::Binding(Box::new(error))
	}
}
impl core::fmt::Display for Error {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		match self {
			Self::Binding(e) => e.fmt(f),
			Self::Timeout(what) => f.write_str(what),
			Self::Reply(e) => e.fmt(f),
			Self::Custody(e) => e.fmt(f),
			Self::Membership(e) => e.fmt(f),
			Self::History(e) => e.fmt(f),
			Self::Transfer(e) => e.fmt(f),
			Self::Invitation(e) => e.fmt(f),
			Self::Query(e) => e.fmt(f),
			Self::Bridge(e) => e.fmt(f),
			Self::Directory(e) => e.fmt(f),
			Self::Archive(e) => e.fmt(f),
			Self::ArchiveShare(e) => e.fmt(f),
			Self::Registration(e) => e.fmt(f),
			Self::Introduction(e) => e.fmt(f),
			Self::Signaling(e) => e.fmt(f),
			Self::Direct(e) => e.fmt(f),
			Self::Inbox(e) => e.fmt(f),
			Self::Sources(e) => e.fmt(f),
		}
	}
}
impl core::error::Error for Error {}
/// Multiple room/directory clients share this connection. Dropping the final
/// owner closes its Session; leaving one room only drops that room's owner.
#[derive(Clone)]
pub struct Client<D> {
	session: Rc<Session>,
	deadline: D,
	directory_watches: directory::watch::Registry,
	directory_names: directory::registration::Registry,
}
/// A connection cache retains neither a Session owner nor a live capability
/// client. Upgrading shares the same directory-watch replacement authority.
pub struct WeakClient {
	session: std::rc::Weak<Session>,
	directory_watches: directory::watch::Registry,
	directory_names: directory::registration::Registry,
}
impl WeakClient {
	pub fn upgrade<D: Deadline>(&self, deadline: D) -> Option<Client<D>> {
		Some(Client {
			session: self.session.upgrade()?,
			deadline,
			directory_watches: self.directory_watches.clone(),
			directory_names: self.directory_names.clone(),
		})
	}
}
impl<D: Deadline> Client<D> {
	pub fn new(session: Session, deadline: D) -> Self {
		Self::from_shared_session(Rc::new(session.with_gc()), deadline)
	}
	pub(crate) fn from_shared_session(session: Rc<Session>, deadline: D) -> Self {
		Self {
			session,
			deadline,
			directory_watches: Default::default(),
			directory_names: Default::default(),
		}
	}
	pub fn session(&self) -> &Session {
		&self.session
	}
	pub fn downgrade(&self) -> WeakClient {
		WeakClient {
			session: Rc::downgrade(&self.session),
			directory_watches: self.directory_watches.clone(),
			directory_names: self.directory_names.clone(),
		}
	}
	/// Relinquish this client's application handle. An application-owned
	/// connection retires with its last client; a sibling client or Host-retained
	/// dial keeps its connection usable.
	pub async fn relinquish(self) -> Result<(), Error> {
		let Self {
			session,
			deadline: _,
			directory_watches,
			directory_names,
		} = self;
		drop(directory_watches);
		drop(directory_names);
		match Rc::try_unwrap(session) {
			Ok(session) => session
				.relinquish(glowcap::PendingWork::Cancel)
				.await
				.map_err(Error::from),
			Err(_) => Ok(()),
		}
	}
	/// Platform execution services shared by this connection's application work.
	pub fn platform(&self) -> &D {
		&self.deadline
	}
	pub async fn enliven(&self, link: &str) -> Result<Ref, Error> {
		self.deadline
			.within(authority::REQUEST_TIMEOUT_MS, self.session.enliven(link))
			.await
			.ok_or(Error::Timeout("the room authority did not become available"))?
			.map_err(Error::from)
	}
	async fn ask(&self, target: &Ref, verb: &'static str, args: &[&str], what: &'static str) -> Result<Reply, Error> {
		// The binding accepts owned string arguments. These temporary copies end
		// immediately after send mints its vow; they do not survive the await.
		let pending = {
			let arguments: Vec<Argument> = args.iter().map(|v| Argument::String((*v).into())).collect();
			self.call(target, verb, &arguments, what)
		};
		pending.await
	}
	fn call(
		&self,
		target: &Ref,
		verb: &'static str,
		args: &[Argument],
		what: &'static str,
	) -> impl Future<Output = Result<Reply, Error>> + use<'_, D> {
		self.call_with_timeout(target, verb, args, what, authority::REQUEST_TIMEOUT_MS)
	}
	fn call_with_timeout(
		&self,
		target: &Ref,
		verb: &'static str,
		args: &[Argument],
		what: &'static str,
		milliseconds: u64,
	) -> impl Future<Output = Result<Reply, Error>> + use<'_, D> {
		self.call_on(&self.session, target, verb, args, what, milliseconds)
	}
	fn call_on(
		&self,
		session: &Session,
		target: &Ref,
		verb: &'static str,
		args: &[Argument],
		what: &'static str,
		milliseconds: u64,
	) -> impl Future<Output = Result<Reply, Error>> + use<'_, D> {
		let pending = session.send(target, verb, args);
		async move {
			self.deadline
				.within(milliseconds, pending.into_future())
				.await
				.ok_or(Error::Timeout(what))?
				.map(Reply)
				.map_err(Error::from)
		}
	}
}
struct Reply(Argument);
impl authority::Reply for Reply {
	fn text(&self) -> Option<&str> {
		self.0.as_str()
	}
	fn list_len(&self) -> Option<usize> {
		self.0.as_list().map(<[Argument]>::len)
	}
	fn list_text(&self, index: usize) -> Option<&str> {
		self.0.as_list()?.get(index)?.as_str()
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use rooms_application::failure::FailureCode;

	#[test]
	fn peer_retry_uses_the_owned_wire_code_not_its_detail() {
		let coded = format!(
			"{}: detail mentioning {}",
			FailureCode::IntroductionPending.wire(),
			FailureCode::NickTaken.wire()
		);
		assert_eq!(coded_retry(&coded), Some(Retry::Soon));
		assert_eq!(
			binding_kind_retry(glowcap::ErrorKind::Broken, Some(&coded)),
			Retry::Soon
		);
		assert_eq!(
			binding_kind_retry(glowcap::ErrorKind::InvalidArgument, None),
			Retry::AfterRequestChange
		);
		assert_eq!(
			binding_kind_retry(glowcap::ErrorKind::Malformed, None),
			Retry::AfterStateChange
		);
		assert_eq!(Error::Timeout("late").retry(), Retry::AfterStateChange);
		assert_eq!(Error::Reply(Refusal::Policy).retry(), Retry::AfterRequestOrStateChange);
	}

	#[test]
	fn only_connection_loss_retires_a_selected_peer() {
		use glowcap::ErrorKind;
		for kind in [ErrorKind::Closed, ErrorKind::Io, ErrorKind::TimedOut] {
			assert!(binding_kind_connection_failed(kind));
		}
		for kind in [
			ErrorKind::Broken,
			ErrorKind::InvalidArgument,
			ErrorKind::Malformed,
			ErrorKind::FrameTooLarge,
		] {
			assert!(!binding_kind_connection_failed(kind));
		}
		assert!(Error::Timeout("late").connection_failed());
		assert!(!Error::Reply(Refusal::Policy).connection_failed());
	}
}
