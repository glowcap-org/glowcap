//! One runtime's sender-held file sources across all direct conversations.
//! The core owns retention and read budgets. This adapter owns hosted roots,
//! asynchronous readers and their deferred answers.
use super::*;
use rooms_application::files::{FileDescription, sources as policy};
use std::{
	cell::{Cell, RefCell},
	pin::Pin,
	rc::Weak,
};
mod hosting;

/// A bounded random-access read. The future must own its I/O and return exactly
/// the requested span. Dropping it cancels observation. Its source stays charged
/// throughout that future's lifetime. No whole-file assembly is required.
pub trait Reader {
	fn read(&self, offset: usize, length: usize) -> Pin<Box<dyn Future<Output = Result<Vec<u8>, String>>>>;
}
enum Backing {
	Frozen(super::files::capture::Captured),
	Reader(Box<dyn Reader>),
}
#[derive(Clone)]
pub struct Source(Rc<SourceData>);
struct SourceData {
	description: FileDescription,
	backing: Backing,
}
impl Source {
	/// Immutable local storage can be retained after upload without reading a
	/// mutable source again. Reader-backed sources retain their streaming path.
	pub fn capture(&self) -> Option<super::files::capture::Captured> {
		match &self.0.backing {
			Backing::Frozen(captured) => Some(captured.clone()),
			Backing::Reader(_) => None,
		}
	}
	pub fn description(&self) -> &FileDescription {
		&self.0.description
	}
	pub fn bytes(description: FileDescription, bytes: Vec<u8>) -> Result<Self, Error> {
		if description.size() != bytes.len() {
			return Err(policy::Error::Source.into());
		}
		let captured =
			super::files::capture::Captured::from_shared(description, std::sync::Arc::new(bytes.into_boxed_slice()))
				.map_err(|_| policy::Error::Source)?;
		Ok(Self::captured(captured))
	}
	/// Adopt immutable capture storage without another full-file read or copy.
	pub fn captured(captured: super::files::capture::Captured) -> Self {
		Self(Rc::new(SourceData {
			description: captured.description().clone(),
			backing: Backing::Frozen(captured),
		}))
	}

	pub fn reader(description: FileDescription, reader: impl Reader + 'static) -> Self {
		Self(Rc::new(SourceData {
			description,
			backing: Backing::Reader(Box::new(reader)),
		}))
	}
	/// Local observers read the retained source independently of its exported
	/// one-pass grant. Network encoding copies only the returned bounded span.
	pub async fn read<D: Deadline>(
		&self,
		clock: &D,
		offset: u64,
		maximum: usize,
	) -> Result<super::files::capture::Chunk, String> {
		let length = rooms_application::files::transfer::read_length(self.description().size(), offset, maximum)
			.map_err(|error| error.to_string())?;
		if length == 0 {
			return Ok(Vec::new().into());
		}
		match &self.0.backing {
			Backing::Frozen(captured) => captured.span(offset, length),
			Backing::Reader(reader) => {
				let bytes = clock
					.within(
						rooms_application::files::transfer::STALL_MS,
						reader.read(offset as usize, length),
					)
					.await
					.ok_or("the local source stopped answering")??;
				if bytes.len() != length {
					return Err("local source returned an invalid span".into());
				}
				Ok(bytes.into())
			}
		}
	}
	pub async fn materialize<D: Deadline>(&self, clock: &D) -> Result<super::files::capture::Captured, String> {
		use super::files::capture::{Captured, Chunk};
		if let Backing::Frozen(captured) = &self.0.backing {
			return Ok(captured.clone());
		}
		Captured::read_with(self.description().clone(), |offset, length| async move {
			self.read(clock, offset, length).await.map(Chunk::into_vec)
		})
		.await
	}
}
struct Job {
	done: Cell<bool>,
}
struct State<D: Tasks> {
	pool: RefCell<policy::Sources<Source>>,
	jobs: RefCell<Vec<(Rc<Job>, D::Task)>>,
	failure: RefCell<Option<Failure>>,
}
pub struct Failure {
	pub first: glowcap::Error,
	pub count: usize,
}
pub struct Sources<D: Tasks> {
	state: Rc<State<D>>,
	platform: D,
}
struct SendPolicy {
	suffix: Vec<Argument>,
	retain: bool,
}
impl<D: Deadline + Tasks + Clone + 'static> Sources<D> {
	/// Create once per application runtime and share by borrowing or Rc. The
	/// owner must outlive delivered files. Dropping it retires sources and tasks.
	pub fn new(platform: D) -> Self {
		Self {
			state: Rc::new(State {
				pool: RefCell::new(Default::default()),
				jobs: RefCell::new(Vec::new()),
				failure: RefCell::new(None),
			}),
			platform,
		}
	}
	pub fn usage(&self) -> policy::Usage {
		self.state.pool.borrow_mut().usage()
	}
	pub fn take_failure(&self) -> Option<Failure> {
		self.state.failure.borrow_mut().take()
	}
	/// Keep exact one-pass sources until the application observes ingestion
	/// settlement. A receipt admission acknowledgement does not end this lease.
	/// The same owner remains available after a lost reply for exact replay.
	/// Dropping it expires the sources without claiming that remote work ended.
	pub fn lend(&self, client: &Client<D>, sources: Vec<Source>) -> Result<LentSources<D>, Error> {
		self.lend_through(Caller::Remote(client.clone()), sources, false)
	}
	/// Lend from the application's existing Host, including transport-free
	/// managed uploads. The same pool and lease own asynchronous source reads.
	pub fn lend_local(&self, host: &glowcap::Host, sources: Vec<Source>) -> Result<LentSources<D>, Error> {
		self.lend_through(
			Caller::Local {
				host: host.clone(),
				platform: self.platform.clone(),
			},
			sources,
			false,
		)
	}
	/// Keep managed upload backing readable through independent archive reads
	/// and subsequent line changes. Existing hosted leases own retention. No
	/// second source table or full-file materialization is introduced.
	pub(crate) fn lend_repeatable_local(
		&self,
		host: &glowcap::Host,
		sources: Vec<Source>,
	) -> Result<LentSources<D>, Error> {
		self.lend_through(
			Caller::Local {
				host: host.clone(),
				platform: self.platform.clone(),
			},
			sources,
			true,
		)
	}
	fn lend_through(&self, caller: Caller<D>, sources: Vec<Source>, repeatable: bool) -> Result<LentSources<D>, Error> {
		let sources = sources
			.into_iter()
			.map(|source| (source.description().clone(), source))
			.collect();
		let blobs = if repeatable {
			self.state.pool.borrow_mut().retain_repeatable(sources)?
		} else {
			self.state.pool.borrow_mut().retain(sources)?
		};
		let mut prepared = LentSources {
			roots: Vec::with_capacity(blobs.len()),
			blobs: blobs.into_iter().map(|blob| blob.lease()).collect(),
			delivered: Cell::new(false),
			_caller: caller,
		};
		let host = match &prepared._caller {
			Caller::Remote(client) => client.session().host(),
			Caller::Local { host, .. } => host.clone(),
		};
		for blob in &prepared.blobs {
			prepared
				.roots
				.push(host.spawn(self.behavior(blob.blob().lease(), host.clone()))?);
		}
		Ok(prepared)
	}
	/// Send once. Cancellation and failure expire all this message's sources.
	/// The original remote result is retained, including delegated line authority.
	pub async fn send(
		&self,
		client: &Client<D>,
		target: &Ref,
		verb: &'static str,
		leading: Vec<Argument>,
		sources: Vec<Source>,
	) -> Result<Argument, Error> {
		self.send_with_policy(
			Caller::Remote(client.clone()),
			target,
			verb,
			leading,
			sources,
			SendPolicy {
				suffix: Vec::new(),
				retain: true,
			},
		)
		.await
	}
	pub async fn send_appended(
		&self,
		client: &Client<D>,
		target: &Ref,
		verb: &'static str,
		leading: Vec<Argument>,
		sources: Vec<Source>,
		suffix: Vec<Argument>,
	) -> Result<Argument, Error> {
		self.send_with_policy(
			Caller::Remote(client.clone()),
			target,
			verb,
			leading,
			sources,
			SendPolicy { suffix, retain: true },
		)
		.await
	}
	/// Sources expire when this call ends, including after a successful reply.
	/// Use for an ingestion whose acknowledgement means it owns the bytes.
	pub async fn send_scoped(
		&self,
		client: &Client<D>,
		target: &Ref,
		verb: &'static str,
		leading: Vec<Argument>,
		sources: Vec<Source>,
	) -> Result<Argument, Error> {
		self.send_with_policy(
			Caller::Remote(client.clone()),
			target,
			verb,
			leading,
			sources,
			SendPolicy {
				suffix: Vec::new(),
				retain: false,
			},
		)
		.await
	}
	async fn send_with_policy(
		&self,
		caller: Caller<D>,
		target: &Ref,
		verb: &'static str,
		mut leading: Vec<Argument>,
		sources: Vec<Source>,
		policy: SendPolicy,
	) -> Result<Argument, Error> {
		let prepared = self.lend_through(caller.clone(), sources, false)?;
		prepared.append_to(&mut leading);
		leading.extend(policy.suffix);
		let pending = caller.call(
			target,
			verb,
			&leading,
			"the peer did not answer the message carrying its files",
		);
		drop(leading);
		let reply = pending.await?;
		prepared.delivered.set(policy.retain);
		Ok(reply)
	}
	pub async fn send_scoped_local(
		&self,
		host: &glowcap::Host,
		target: &Ref,
		verb: &'static str,
		leading: Vec<Argument>,
		sources: Vec<Source>,
	) -> Result<Argument, Error> {
		self.send_with_policy(
			Caller::Local {
				host: host.clone(),
				platform: self.platform.clone(),
			},
			target,
			verb,
			leading,
			sources,
			SendPolicy {
				suffix: Vec::new(),
				retain: false,
			},
		)
		.await
	}
}
/// One bounded source population and its existing connection. It owns no file
/// assembly or second pool. Attachment rendering borrows descriptions and roots.
/// Only ordinary outgoing Argument admission copies their scalar wire material.
pub struct LentSources<D> {
	blobs: Vec<policy::Lease<Source>>,
	roots: Vec<Ref>,
	delivered: Cell<bool>,
	_caller: Caller<D>,
}
impl<D> LentSources<D> {
	pub(super) fn delivery_started(&self) {
		self.delivered.set(true);
	}
	/// The pool separately charges declared source bytes and asynchronous reads.
	/// These two owned vectors retain lease/root spines until exact settlement.
	pub fn retained_bytes(&self) -> usize {
		self.blobs
			.capacity()
			.saturating_mul(size_of::<policy::Lease<Source>>())
			.saturating_add(self.roots.capacity().saturating_mul(size_of::<Ref>()))
	}
	pub fn append_to(&self, arguments: &mut Vec<Argument>) {
		for (blob, root) in self.blobs.iter().zip(&self.roots) {
			super::files::append_attachment(arguments, blob.blob().description(), root);
		}
	}
}
impl<D> Drop for LentSources<D> {
	fn drop(&mut self) {
		if !self.delivered.get() {
			for blob in &self.blobs {
				blob.blob().expire();
			}
		}
	}
}
// A worker is removed on success, refusal, cancellation or unwind. The callback
// holds only Weak<State>, so exported blobs do not keep their runtime alive.
struct Completion<D: Tasks> {
	state: Weak<State<D>>,
	job: Rc<Job>,
}
impl<D: Tasks> Drop for Completion<D> {
	fn drop(&mut self) {
		self.job.done.set(true);
		if let Some(state) = self.state.upgrade() {
			let removed = {
				let mut jobs = state.jobs.borrow_mut();
				jobs.iter()
					.position(|(job, _)| Rc::ptr_eq(job, &self.job))
					.map(|at| jobs.swap_remove(at))
			};
			drop(removed);
		}
	}
}
