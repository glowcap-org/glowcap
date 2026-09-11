//! Durable acceptance precedes inbox publication. This owner composes the
//! shared publisher; a required receiver factory supplies the message effects.
use crate::directory_runtime::{AcceptedDirect, DirectoryRuntime, RegistrationWork};
use glowcap::Behavior;
use rooms_application::direct::publication;
use rooms_application::failure::{Failure, FailureCode};
use rooms_glowcap::client::{
	direct::publisher::{Offerer, Publisher},
	Error,
};
use std::{
	cell::{Cell, RefCell},
	rc::Rc,
};

/// Direct inbox publication adds cryptographic alias entropy to directory execution.
pub trait Platform: crate::directory_runtime::Platform + rooms_glowcap::client::direct::publisher::Entropy {}
impl<T: crate::directory_runtime::Platform + rooms_glowcap::client::direct::publisher::Entropy> Platform for T {}

pub const OFFER_LIMIT: usize = 32;

type Factory = dyn FnMut(AcceptedDirect) -> Result<Behavior, Error>;
struct Published<P: Platform> {
	accepted: AcceptedDirect,
	offerer: Rc<Offerer<P>>,
}
pub struct DirectPublications<P: Platform> {
	publisher: Publisher<P>,
	make: Rc<RefCell<Factory>>,
	rows: RefCell<Vec<Published<P>>>,
	closed: Cell<bool>,
	pending: Cell<usize>,
}
impl<P: Platform> DirectPublications<P> {
	/// The factory must implement actual direct receiver effects. Its behavior
	/// must not strongly retain the Host that publishes it. The outer actor
	/// checks accepted authority before every delivery; asynchronous effects
	/// must also check their supplied context after awaiting.
	pub fn new(publisher: Publisher<P>, make: impl FnMut(AcceptedDirect) -> Result<Behavior, Error> + 'static) -> Self {
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
	pub async fn offer(
		&self,
		runtime: &DirectoryRuntime<P>,
		work: &RegistrationWork,
	) -> Result<AcceptedDirect, String> {
		self.require_open()?;
		if self.pending.get() == OFFER_LIMIT {
			return Err("the direct publication owner has too many outstanding offers".into());
		}
		self.pending.set(self.pending.get() + 1);
		let _pending = Pending(&self.pending);
		self.reconcile().await?;
		self.require_open()?;
		let accepted = runtime.accept_direct(work).await?;
		self.require_open()?;
		let directory = runtime.direct_directory(&accepted)?;
		let offerer = {
			let mut rows = self.rows.borrow_mut();
			match rows.iter().position(|row| row.accepted.same_context(&accepted)) {
				Some(index) => rows[index].offerer.clone(),
				None => {
					if rows.len() == publication::DEFAULT_INBOX_LIMIT {
						return Err("the session direct publication limit is full".into());
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
						.map_err(|e| e.to_string())?;
					let offerer = Rc::new(offerer);
					rows.push(Published {
						accepted: accepted.clone(),
						offerer: offerer.clone(),
					});
					offerer
				}
			}
		};
		let peer = accepted
			.peer()
			.text()
			.as_str()
			.ok_or("the direct peer is not valid UTF-8")?;
		let result = offerer
			.offer(&directory, peer, accepted.registration())
			.await
			.map_err(|e| e.to_string());
		self.require_open()?;
		if !accepted.current() {
			self.reconcile().await?;
			return Err("the direct conversation retired while offering its inbox".into());
		}
		result?;
		Ok(accepted)
	}
	/// Retired actors refuse immediately, even before cleanup runs. Removing
	/// an owner queues its exact aliases in the shared ledger; failed Host
	/// cleanup keeps those aliases charged and this method can be retried.
	pub async fn reconcile(&self) -> Result<(), String> {
		self.rows.borrow_mut().retain(|row| {
			if row.accepted.current() {
				return true;
			}
			row.offerer.retire();
			false
		});
		self.publisher.reconcile().await.map_err(|e| e.to_string())
	}
	fn require_open(&self) -> Result<(), String> {
		if self.closed.get() {
			return Err("direct publication owner is closed".into());
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
	pub async fn close(&self) -> Result<(), String> {
		self.retire();
		self.publisher.reconcile().await.map_err(|e| e.to_string())
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
