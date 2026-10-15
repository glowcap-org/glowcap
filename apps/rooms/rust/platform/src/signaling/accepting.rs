//! The answering side of [`DirectorySignaling`]: offers a directory delivered
//! to this peer's signaling inbox.
//!
//! The embedding reads its inbox and hands each offer to
//! [`DirectorySignaling::offered`] with the route it came in on. The offer
//! names the Host key its member registered, the one the directory routes
//! that member's signaling by. The WebRTC listener pins the channel to
//! it, so the accepted session names who connected.
//! The answer and each local candidate go back through the same route under
//! the offer's exchange id, and [`DirectorySignaling::far_candidate`] hands
//! the member's candidates to the listener. An offer this peer refuses is
//! declined through the route with the refusal, so the member hears why at
//! once.
use super::*;
use rooms_application::signaling::{Id, Reason, TIMEOUT_MS};
use rooms_glowcap::client::Deadline;

/// The directory route an offer came in on.
pub trait Reply {
	fn answer(&self, id: &Id, answer: &Description) -> Result<(), Error>;
	fn candidate(&self, id: &Id, candidate: &Candidate) -> Result<(), Error>;
	fn decline(&self, id: &Id, reason: &Reason) -> Result<(), Error>;
	/// The key of the directory session the route runs over, while it is open.
	fn directory(&self) -> Option<String>;
}
impl<P: Deadline + Tasks + Clone + 'static> Reply for signaling::Route<P> {
	fn answer(&self, id: &Id, answer: &Description) -> Result<(), Error> {
		self.signal_answer(id, answer)
	}
	fn candidate(&self, id: &Id, candidate: &Candidate) -> Result<(), Error> {
		self.signal_candidate(id, candidate)
	}
	fn decline(&self, id: &Id, reason: &Reason) -> Result<(), Error> {
		self.signal_decline(id, reason)
	}
	fn directory(&self) -> Option<String> {
		let identity = self.session()?.partner_identity().ok()?;
		Some(identity.designator)
	}
}

/// What takes an offer once its signaling has a route: the WebRTC listener.
pub trait Answerer {
	fn provide_offer(&self, designator: &str, sdp: &str) -> glowcap::Result<u64>;
	fn fail_exchange(&self, exchange: u64) -> glowcap::Result<()>;
}
impl Answerer for glowcap::webrtc::Server {
	fn provide_offer(&self, designator: &str, sdp: &str) -> glowcap::Result<u64> {
		glowcap::webrtc::Server::provide_offer(self, designator, sdp)
	}
	fn fail_exchange(&self, exchange: u64) -> glowcap::Result<()> {
		glowcap::webrtc::Server::fail_exchange(self, exchange)
	}
}

/// An offer on its way into the listener: the directory's id for it and the
/// route it came in on.
pub(super) struct Offer<R> {
	id: Id,
	reply: Rc<R>,
}

/// The offers being answered, keyed by the listener's exchange id.
pub(super) type Accepts<R, T> = RefCell<HashMap<u64, Accept<R, T>>>;
pub(super) struct Accept<R, T> {
	id: Id,
	reply: Rc<R>,
	sink: Option<Rc<dyn Fn(String)>>,
	/// Gives the accept up when its channel has not opened by the signaling
	/// deadline. Dropping the entry drops it.
	_deadline: Option<T>,
}

impl<P, X> DirectorySignaling<P, X>
where
	P: Tasks + Deadline + Clone + 'static,
	X: Exchanges + 'static,
{
	/// Answer an offer that `reply`'s directory delivered under `id`. `from`
	/// is the designator the offering member registered, and an offer without
	/// one is refused, because nothing could name its channel. The answer
	/// goes out before this returns. A refused offer is declined with the
	/// refusal, which is also returned, and a failure to decline it is
	/// reported. An accept whose channel has not opened within the signaling
	/// deadline is given up, and a failure to give it up is reported.
	pub fn offered<A: Answerer + 'static>(
		&self,
		answerer: &Rc<A>,
		reply: Rc<X::Reply>,
		id: Id,
		from: Option<Id>,
		offer: &Description,
	) -> glowcap::Result<()> {
		let directory = reply.directory();
		let Err(refused) = self.accept(answerer, &reply, directory.as_deref(), id.clone(), from.as_ref(), offer) else {
			return Ok(());
		};
		let declined = Reason::parse(&refused.to_string())
			.map_err(Error::from)
			.and_then(|reason| reply.decline(&id, &reason));
		if let Err(error) = declined {
			self.reporter(from.as_ref().map(Id::as_str), directory.as_deref())
				.failed(Stage::Decline, error);
		}
		Err(refused)
	}

	fn accept<A: Answerer + 'static>(
		&self,
		answerer: &Rc<A>,
		reply: &Rc<X::Reply>,
		directory: Option<&str>,
		id: Id,
		from: Option<&Id>,
		offer: &Description,
	) -> glowcap::Result<()> {
		let Some(from) = from else {
			return Err(refusal(
				"the offering member registered no Host key, so its channel names nobody",
			));
		};
		let designator = from.as_str();
		let previous = self.answering.replace(Some(Offer {
			id,
			reply: reply.clone(),
		}));
		debug_assert!(previous.is_none(), "the listener takes one offer at a time");
		let provided = answerer.provide_offer(designator, offer.as_str());
		// The answer took the offer when it went out. One still here was
		// refused before an answer existed.
		self.answering.take();
		let exchange = provided?;
		let (platform, answerer, reporter) = (
			self.platform.clone(),
			answerer.clone(),
			self.reporter(Some(designator), directory),
		);
		let deadline = self.platform.spawn(async move {
			platform.within(TIMEOUT_MS, std::future::pending::<()>()).await;
			if let Err(error) = answerer.fail_exchange(exchange) {
				reporter.failed(Stage::GiveUp, Error::from(error));
			}
		});
		// The channel may already have opened and ended the accept, and then
		// the deadline has nothing to give up.
		if let Some(accept) = self.accepts.borrow_mut().get_mut(&exchange) {
			accept._deadline = Some(deadline);
		}
		Ok(())
	}

	/// Hand the listener one of the offering member's candidates for the
	/// offer `id`. The inbox delivers in order and the listener subscribes
	/// while it takes the offer, so a candidate whose offer is not being
	/// answered belongs to one that already ended, and it is dropped.
	pub fn far_candidate(&self, id: &Id, candidate: &Candidate) {
		let sink = self
			.accepts
			.borrow()
			.values()
			.find(|accept| accept.id == *id)
			.and_then(|accept| accept.sink.clone());
		if let Some(sink) = sink {
			sink(candidate.as_str().to_owned());
		}
	}
}

impl<P: Tasks + 'static, X: Exchanges + 'static> DirectorySignaling<P, X> {
	/// Send the answer for the offer being handed in, which makes it the
	/// accept `exchange`.
	pub(super) fn send_answer(&self, exchange: u64, sdp: &str) -> glowcap::Result<()> {
		let offer = self
			.answering
			.take()
			.ok_or_else(|| refusal("no offer is being answered"))?;
		let answer = Description::parse(sdp)
			.map_err(|error| refusal(format!("the answer is not a signaling description: {error}")))?;
		offer.reply.answer(&offer.id, &answer).map_err(carry)?;
		self.accepts.borrow_mut().insert(
			exchange,
			Accept {
				id: offer.id,
				reply: offer.reply,
				sink: None,
				_deadline: None,
			},
		);
		Ok(())
	}
	pub(super) fn send_candidate(&self, exchange: u64, candidate: &Candidate) -> glowcap::Result<()> {
		let (reply, id) = self
			.accepts
			.borrow()
			.get(&exchange)
			.map(|accept| (accept.reply.clone(), accept.id.clone()))
			.ok_or_else(|| refusal("no offer is being answered under this exchange"))?;
		reply.candidate(&id, candidate).map_err(carry)
	}
	pub(super) fn subscribe_accept(&self, exchange: u64, sink: Box<dyn Fn(String)>) -> Box<dyn FnOnce()> {
		if let Some(accept) = self.accepts.borrow_mut().get_mut(&exchange) {
			accept.sink = Some(Rc::from(sink));
		}
		let accepts = Rc::downgrade(&self.accepts);
		Box::new(move || {
			if let Some(accepts) = accepts.upgrade() {
				// Dropped after the borrow ends, because dropping its deadline
				// task may run code that reads the table.
				let removed = accepts.borrow_mut().remove(&exchange);
				drop(removed);
			}
		})
	}
}
