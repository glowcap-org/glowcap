//! Host-scoped direct inbox publication. Directory owners share a pure ledger.
//! Native alias effects run outside delivering turns and expose actual failures.
use crate::client::{Deadline, Error, directory::Directory};
use glowcap::{Behavior, Host, Ref, Session};
use rooms_application::failure::{Failure, FailureCode};
use rooms_application::{direct::publication as policy, directory::registration::Id};
use std::{cell::RefCell, future::poll_fn, rc::Rc, task::Poll};
pub trait Entropy {
	fn inbox_entropy(&self) -> Result<[u8; 32], Error>;
}
#[derive(Clone)]
pub struct Publisher<D> {
	host: Host,
	ledger: Rc<RefCell<policy::Ledger>>,
	platform: D,
}
impl<D: Deadline + Entropy + Clone> Publisher<D> {
	pub fn new(host: Host, platform: D) -> Result<Self, Error> {
		Self::with_limit(host, platform, policy::DEFAULT_INBOX_LIMIT)
	}
	pub fn with_limit(host: Host, platform: D, limit: usize) -> Result<Self, Error> {
		let initial = policy::Ledger::new(limit)?;
		let ledger = host.application_state(move || RefCell::new(initial))?;
		if ledger.borrow().limit() != limit {
			return Err(policy::Error::Limit.into());
		}
		Ok(Self { host, ledger, platform })
	}
	pub fn held(&self) -> usize {
		self.ledger.borrow().held()
	}
	/// The factory runs after asynchronous retirement cleanup and may refuse if
	/// its application context changed. Refusal releases the provisional alias.
	pub fn offerer(
		&self,
		make: impl FnMut(&str, &Id) -> Result<Behavior, Error> + 'static,
	) -> Result<Offerer<D>, Error> {
		Ok(Offerer {
			publisher: self.clone(),
			scope: self.ledger.borrow_mut().scope()?,
			make: RefCell::new(Box::new(make)),
			skip: None,
		})
	}
	/// Retry exact retired aliases, including dropped offerers. A failed remove
	/// keeps its ledger row and capacity. This operation is cancellation-safe.
	/// Every completed host remove is reflected before another await.
	pub async fn reconcile(&self) -> Result<(), Error> {
		outside_turn().await;
		let retired = self.ledger.borrow_mut().retirements();
		for (index, inbox) in retired.iter().enumerate() {
			if index > 0 && index % 64 == 0 {
				outside_turn().await;
			}
			// Another owner may finish this alias while the batch yields. Check
			// its retained slot, not just its name: that name may now be reused.
			if !inbox.retiring() {
				continue;
			}
			self.host.unpublish(inbox.alias())?;
			self.ledger.borrow_mut().removed(inbox)?;
		}
		Ok(())
	}
}
type Factory = Box<dyn FnMut(&str, &Id) -> Result<Behavior, Error>>;
type Skip = Box<dyn Fn(&str) -> bool>;
pub struct Offerer<D> {
	publisher: Publisher<D>,
	scope: policy::Scope,
	make: RefCell<Factory>,
	skip: Option<Skip>,
}
impl<D: Deadline + Entropy + Clone> Offerer<D> {
	pub fn with_skip(mut self, skip: impl Fn(&str) -> bool + 'static) -> Self {
		self.skip = Some(Box::new(skip));
		self
	}
	/// Pass the current directory on every offer, including after reconnect.
	/// Alias selection and publication form one synchronous transition after
	/// cleanup. Concurrent offers reuse that alias while awaiting independent
	/// directory acknowledgements. No factory or ledger borrow spans a wait.
	/// Cancelling an acknowledged or unacknowledged offer retains its published
	/// alias for re-offer. Only forget/close ends that registration's authority.
	pub async fn offer(&self, directory: &Directory<D>, peer: &str, id: &Id, opening: &str) -> Result<(), Error> {
		if self.skip.as_ref().is_some_and(|skip| skip(peer)) {
			return Ok(());
		}
		let session = directory.client().session();
		let inbox = self.publish(session, peer, id).await?;
		let reference = session.published_ref(inbox.alias())?.ok_or(policy::Error::Phase)?;
		self.submit(directory, peer, id, opening, &inbox, &reference).await
	}
	/// Publish on a separate inbox Host and import through an established
	/// connection to it before offering the capability to the directory.
	/// `exporter` and `importer` are the two ends of that connection. Their
	/// host owner establishes and retains the pair. The importer must belong
	/// to the directory Host. Its exporter locator must name the public inbox
	/// endpoint, since the directory will redeem the resulting handoff there.
	pub async fn offer_via(
		&self,
		directory: &Directory<D>,
		exporter: &Session,
		importer: &Session,
		peer: &str,
		id: &Id,
		opening: &str,
	) -> Result<(), Error> {
		if self.skip.as_ref().is_some_and(|skip| skip(peer)) {
			return Ok(());
		}
		if !importer.host().same_host(&directory.client().session().host()) {
			return Err(policy::Error::Host.into());
		}
		let inbox = self.publish(exporter, peer, id).await?;
		let reference = self
			.publisher
			.platform
			.within(
				rooms_application::room::authority::REQUEST_TIMEOUT_MS,
				importer.fetch(inbox.alias()),
			)
			.await
			.ok_or(Error::Timeout("the shared inbox did not become available"))??;
		if !inbox.live() {
			return Err(policy::Error::Closed.into());
		}
		self.submit(directory, peer, id, opening, &inbox, &reference).await
	}
	async fn publish(&self, session: &Session, peer: &str, id: &Id) -> Result<policy::Inbox, Error> {
		if !self.publisher.host.same_host(&session.host()) {
			return Err(policy::Error::Host.into());
		}
		self.publisher.reconcile().await?;
		let existing = self.publisher.ledger.borrow().existing(&self.scope, peer, id)?;
		let inbox = match existing {
			Some(inbox) => inbox,
			None => {
				let entropy = self.publisher.platform.inbox_entropy()?;
				self.publisher
					.ledger
					.borrow_mut()
					.reserve(&self.scope, peer, id, entropy)?
			}
		};
		let _reservation = Reservation {
			ledger: self.publisher.ledger.clone(),
			inbox: inbox.clone(),
		};
		if !inbox.published() {
			let mut behavior = (self.make.borrow_mut())(inbox.peer(), inbox.registration())?;
			if !inbox.publishable() {
				return Err(policy::Error::Closed.into());
			}
			// Host aliases are mutable. Check after application factory code and
			// before publication, with no yield between, so an entropy collision
			// cannot replace an unrelated actor's name.
			if session.published_ref(inbox.alias())?.is_some() {
				return Err(policy::Error::Collision.into());
			}
			let authority = inbox.clone();
			self.publisher.host.publish(inbox.alias(), || {
				Box::new(move |verb, args| {
					if !authority.live() {
						return Err(Failure {
							code: FailureCode::DirectNotAccepted,
							detail: "the direct inbox registration has ended",
						}
						.to_string());
					}
					behavior(verb, args)
				})
			})?;
			self.publisher.ledger.borrow_mut().published(&inbox)?;
		}
		Ok(inbox)
	}
	async fn submit(
		&self,
		directory: &Directory<D>,
		peer: &str,
		id: &Id,
		opening: &str,
		inbox: &policy::Inbox,
		reference: &Ref,
	) -> Result<(), Error> {
		let result = directory.offer_inbox(peer, id, opening, reference).await;
		if !inbox.live() {
			return Err(policy::Error::Closed.into());
		}
		result
	}
	pub async fn forget(&self, id: &Id) -> Result<(), Error> {
		self.publisher.ledger.borrow_mut().forget(&self.scope, id)?;
		self.publisher.reconcile().await
	}
	/// Revoke issued actors synchronously, even while offers await their reply.
	/// The publisher retains alias capacity until reconcile completes cleanup.
	pub fn retire(&self) {
		self.scope.close();
	}
	pub async fn close(&self) -> Result<(), Error> {
		self.retire();
		self.publisher.reconcile().await
	}
}
struct Reservation {
	ledger: Rc<RefCell<policy::Ledger>>,
	inbox: policy::Inbox,
}
impl Drop for Reservation {
	fn drop(&mut self) {
		// The token was created by this ledger. A successful publication remains
		// retained, including when the later directory offer fails or is cancelled.
		// tolerant: abandon refuses only a token another ledger minted, and
		// this reservation holds the token its own ledger issued.
		let _ = self.ledger.borrow_mut().abandon(&self.inbox);
	}
}
async fn outside_turn() {
	let mut yielded = false;
	poll_fn(|cx| {
		if yielded {
			Poll::Ready(())
		} else {
			yielded = true;
			cx.waker().wake_by_ref();
			Poll::Pending
		}
	})
	.await;
}
