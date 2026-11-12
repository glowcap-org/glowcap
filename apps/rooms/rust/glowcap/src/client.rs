//! Shared client execution over the existing Rust Host binding. The platform
//! supplies deadline scheduling. Application reply policy lives in Rooms core.
use glowcap::{Argument, Ref, Session};
use rooms_application::room::authority;
use std::{
	future::{Future, IntoFuture},
	rc::Rc,
};
mod caller;
pub(crate) use caller::Caller;
#[cfg(feature = "loam")]
pub mod access;
pub mod archive;
pub mod direct;
pub mod directory;
mod error;
pub use error::{Error, binding_admission_refusal, binding_failure, binding_retry, clears_with_time, reach_code};
pub mod files;
pub mod invitation;
pub mod manager;
pub mod posted_line;
#[cfg(feature = "loam")]
mod retained;
pub mod room;
pub mod session;
pub mod sources;
pub mod stewardship;
#[cfg(feature = "loam")]
pub mod workspace;

/// Ending a deadline drops the pending observation. The binding retains and
/// retires any protocol work and releases late projected reply occurrences.
pub trait Deadline {
	/// Monotonic milliseconds in this embedding's clock domain. Wall time is
	/// unsuitable: clock corrections must not restore spent work allowance.
	fn monotonic_millis(&self) -> u64;
	fn within<T>(&self, milliseconds: u64, work: impl Future<Output = T>) -> impl Future<Output = Option<T>>;
}
/// Platform task custody. Dropping Task cancels its future and releases all
/// resources held by that observation. Detached background work is not allowed.
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
/// Multiple room/directory clients share this connection. Dropping the final
/// owner closes its Session. Leaving one room only drops that room's owner.
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
		Self::from_shared_session(Rc::new(session), deadline)
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
	/// connection retires with its last client. A sibling client or Host-retained
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
		self.await_reply(pending, what, milliseconds)
	}
	fn admitted_call(
		&self,
		target: &Ref,
		verb: &'static str,
		args: &[Argument],
		what: &'static str,
	) -> Result<impl Future<Output = Result<Reply, Error>> + use<'_, D>, Error> {
		let pending = self
			.session
			.send(target, verb, args)
			.into_admitted()
			.map_err(|error| Error::Unsent(Box::new(error)))?;
		Ok(self.await_reply(pending, what, authority::REQUEST_TIMEOUT_MS))
	}
	async fn await_reply(
		&self,
		pending: glowcap::RemotePromise,
		what: &'static str,
		milliseconds: u64,
	) -> Result<Reply, Error> {
		self.deadline
			.within(milliseconds, pending.into_future())
			.await
			.ok_or(Error::Timeout(what))?
			.map(Reply)
			.map_err(Error::from)
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
