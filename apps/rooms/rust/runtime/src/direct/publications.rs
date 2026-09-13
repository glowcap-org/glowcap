//! Durable acceptance precedes inbox publication. This owner composes the
//! shared publisher; a required receiver factory supplies the message effects.
use crate::Error;
use crate::directories::runtime::{AcceptedDirect, DirectoryRuntime, RegistrationWork};
use glowcap::Behavior;
use rooms_application::direct::publication;
use rooms_application::failure::{Failure, FailureCode};
use rooms_glowcap::client::{
	Error as ClientError,
	direct::publisher::{Offerer, Publisher},
};
use std::{
	cell::{Cell, RefCell},
	rc::Rc,
};

/// Direct inbox publication adds cryptographic alias entropy to directory execution.
pub trait Platform: crate::directories::runtime::Platform + rooms_glowcap::client::direct::publisher::Entropy {}
impl<T: crate::directories::runtime::Platform + rooms_glowcap::client::direct::publisher::Entropy> Platform for T {}

pub const OFFER_LIMIT: usize = 32;

type Factory = dyn FnMut(AcceptedDirect) -> Result<Behavior, ClientError>;
struct Published<P: Platform> {
	accepted: AcceptedDirect,
	offerer: Offerer<P>,
	acknowledged: Cell<bool>,
}
pub struct DirectPublications<P: Platform> {
	publisher: Publisher<P>,
	make: Rc<RefCell<Factory>>,
	rows: RefCell<Vec<Rc<Published<P>>>>,
	closed: Cell<bool>,
	pending: Cell<usize>,
}
impl<P: Platform> DirectPublications<P> {
	/// The factory must implement actual direct receiver effects. Its behavior
	/// must not strongly retain the Host that publishes it. The outer actor
	/// checks accepted authority before every delivery; asynchronous effects
	/// must also check their supplied context after awaiting.
	pub fn new(
		publisher: Publisher<P>,
		make: impl FnMut(AcceptedDirect) -> Result<Behavior, ClientError> + 'static,
	) -> Self {
		Self {
			publisher,
			make: Rc::new(RefCell::new(make)),
			rows: RefCell::new(Vec::new()),
			closed: Cell::new(false),
			pending: Cell::new(0),
		}
	}
	/// Independent offers share exact aliases without holding the owner across
	/// directory waits. The bound includes acceptance, cleanup and reply waits.
	/// Cancellation preserves published aliases for retry. Drive reconcile on
	/// runtime changes and close before shutting down the Host.
	pub async fn offer(&self, runtime: &DirectoryRuntime<P>, work: &RegistrationWork) -> Result<AcceptedDirect, Error> {
		let _pending = self.enter().await?;
		let accepted = runtime.accept_direct(work).await?;
		self.offer_context(runtime, &accepted).await?;
		Ok(accepted)
	}
	/// A local reopen must refresh the directory's revoked inbox before a
	/// caller can use its route. Reuse an acknowledged offer for this context.
	pub(super) async fn ensure(&self, runtime: &DirectoryRuntime<P>, accepted: &AcceptedDirect) -> Result<(), Error> {
		self.require_open()?;
		if self
			.rows
			.borrow()
			.iter()
			.any(|row| row.accepted.same_context(accepted) && row.acknowledged.get())
		{
			return Ok(());
		}
		let _pending = self.enter().await?;
		self.offer_context(runtime, accepted).await
	}
	async fn enter(&self) -> Result<Pending<'_>, Error> {
		self.require_open()?;
		if self.pending.get() == OFFER_LIMIT {
			return Err(Error::busy(
				"the direct publication owner has too many outstanding offers",
			));
		}
		self.pending.set(self.pending.get() + 1);
		let pending = Pending(&self.pending);
		self.reconcile().await?;
		self.require_open()?;
		Ok(pending)
	}
	async fn offer_context(&self, runtime: &DirectoryRuntime<P>, accepted: &AcceptedDirect) -> Result<(), Error> {
		self.require_open()?;
		let directory = runtime.direct_directory(accepted)?;
		let published = {
			let mut rows = self.rows.borrow_mut();
			match rows.iter().position(|row| row.accepted.same_context(accepted)) {
				Some(index) => rows[index].clone(),
				None => {
					if rows.len() == publication::DEFAULT_INBOX_LIMIT {
						return Err(Error::exhausted("the session direct publication limit is full"));
					}
					let make = self.make.clone();
					let context = accepted.clone();
					let offerer = self
						.publisher
						.offerer(move |_, _| {
							if !context.current() {
								return Err(publication::Error::Closed.into());
							}
							let mut behavior = make.borrow_mut()(context.clone())?;
							if !context.current() {
								return Err(publication::Error::Closed.into());
							}
							let context = context.clone();
							Ok(Box::new(move |verb, args| {
								if !context.current() {
									return Err(Failure {
										code: FailureCode::DirectNotAccepted,
										detail: "that exact direct conversation is no longer accepted",
									}
									.to_string());
								}
								behavior(verb, args)
							}))
						})
						.map_err(Error::peer)?;
					let published = Rc::new(Published {
						accepted: accepted.clone(),
						offerer,
						acknowledged: Cell::new(false),
					});
					rows.push(published.clone());
					published
				}
			}
		};
		let peer = accepted
			.peer()
			.text()
			.as_str()
			.ok_or_else(|| Error::invalid("the direct peer is not valid UTF-8"))?;
		let result = published
			.offerer
			.offer(&directory, peer, accepted.registration())
			.await
			.map_err(Error::peer);
		self.require_open()?;
		if !accepted.current() {
			self.reconcile().await?;
			return Err(Error::closed(
				"the direct conversation retired while offering its inbox",
			));
		}
		result?;
		published.acknowledged.set(true);
		Ok(())
	}
	/// Retired actors refuse immediately, even before cleanup runs. Removing
	/// an owner queues its exact aliases in the shared ledger; failed Host
	/// cleanup keeps those aliases charged and this method can be retried.
	pub async fn reconcile(&self) -> Result<(), Error> {
		self.rows.borrow_mut().retain(|row| {
			if row.accepted.current() {
				return true;
			}
			row.offerer.retire();
			false
		});
		self.publisher.reconcile().await.map_err(Error::peer)
	}
	fn require_open(&self) -> Result<(), Error> {
		if self.closed.get() {
			return Err(Error::closed("direct publication owner is closed"));
		}
		Ok(())
	}
	pub fn pending(&self) -> usize {
		self.pending.get()
	}
	/// Revoke before awaiting cleanup; pending offers cannot restore authority.
	pub fn retire(&self) {
		self.closed.set(true);
		for row in self.rows.borrow_mut().drain(..) {
			row.offerer.retire();
		}
	}
	pub async fn close(&self) -> Result<(), Error> {
		self.retire();
		self.publisher.reconcile().await.map_err(Error::peer)
	}
}

impl<P: Platform> Drop for DirectPublications<P> {
	fn drop(&mut self) {
		self.retire();
	}
}
struct Pending<'a>(&'a Cell<usize>);
impl Drop for Pending<'_> {
	fn drop(&mut self) {
		self.0.set(self.0.get() - 1);
	}
}
