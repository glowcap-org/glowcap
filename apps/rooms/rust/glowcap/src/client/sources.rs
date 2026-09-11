//! One runtime's sender-held file sources across all direct conversations.
//! The core owns retention and read budgets; this adapter owns hosted roots,
//! asynchronous readers and their deferred answers.
use super::*;
use rooms_application::files::{sources as policy, FileDescription};
use std::{
	cell::{Cell, RefCell},
	pin::Pin,
	rc::Weak,
};
mod hosting;

/// A bounded random-access read. The future must own its I/O and return exactly
/// the requested span. Dropping it cancels observation; its source stays charged
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
	pub fn description(&self) -> &FileDescription {
		&self.0.description
	}
	pub fn bytes(description: FileDescription, bytes: Vec<u8>) -> Result<Self, Error> {
		if description.size() != bytes.len() {
			return Err(policy::Error::Source.into());
		}
		let captured =
			super::files::capture::Captured::from_shared(description, std::sync::Arc::new(bytes.into_boxed_slice()))
				.expect("source size was validated");
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
impl<D: Deadline + Tasks + Clone + 'static> Sources<D> {
	/// Create once per application runtime and share by borrowing or Rc. The
	/// owner must outlive delivered files; dropping it retires sources and tasks.
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
	/// Send once. Cancellation and failure expire all this message's sources;
	/// the original remote result is retained, including delegated line authority.
	pub async fn send(
		&self,
		client: &Client<D>,
		target: &Ref,
		verb: &'static str,
		leading: Vec<Argument>,
		sources: Vec<Source>,
	) -> Result<Argument, Error> {
		self.send_with_retention(client, target, verb, leading, sources, true)
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
		self.send_with_retention(client, target, verb, leading, sources, false)
			.await
	}
	async fn send_with_retention(
		&self,
		client: &Client<D>,
		target: &Ref,
		verb: &'static str,
		mut leading: Vec<Argument>,
		sources: Vec<Source>,
		retain: bool,
	) -> Result<Argument, Error> {
		let blobs = self
			.state
			.pool
			.borrow_mut()
			.retain(sources.into_iter().map(|s| (s.description().clone(), s)).collect())?;
		let mut prepared = Prepared {
			blobs,
			roots: Vec::new(),
			delivered: false,
		};
		for blob in &prepared.blobs {
			let root = client.session.spawn_owned(self.behavior(blob.clone()))?;
			super::files::append_attachment(&mut leading, blob.description(), &root);
			prepared.roots.push(root);
		}
		let pending = client.call(
			target,
			verb,
			&leading,
			"the peer did not answer the message carrying its files",
		);
		drop(leading);
		let reply = pending.await?;
		prepared.delivered = retain;
		Ok(reply.0)
	}
}
struct Prepared {
	blobs: Vec<policy::Blob<Source>>,
	roots: Vec<Ref>,
	delivered: bool,
}
impl Drop for Prepared {
	fn drop(&mut self) {
		if !self.delivered {
			for blob in &self.blobs {
				blob.expire();
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
