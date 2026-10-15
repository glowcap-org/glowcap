//! WebRTC signaling for a server peer, carried through its directories.
//!
//! A server peer never dials a browser on its own. The dial opens when the
//! Host follows a reference a directory handed over, and that directory is the
//! one party both peers can reach. So the dial's offer, answer and candidates
//! travel through the directory's signaling exchange, the same exchange a
//! browser member uses. [`DirectorySignaling`] implements the Rust binding's
//! signaling trait over it, and the embedding says which live directory a
//! session key serves through [`Exchanges`]. The same authority answers the
//! offers members send through a directory ([`accepting`]).
use glowcap::webrtc::{SignalingAuthority, Target, refusal};
use rooms_application::signaling::{Candidate, Description};
use rooms_glowcap::client::{Deadline, Error, Tasks, directory::signaling};
use std::{
	cell::RefCell,
	collections::HashMap,
	fmt,
	future::Future,
	pin::Pin,
	rc::{Rc, Weak},
};

pub mod accepting;
#[cfg(test)]
mod tests;
use accepting::Accepts;

/// One dial's signaling exchange through a directory.
pub trait Exchange {
	/// Start the exchange with the local offer, once.
	fn offer(&self, description: &Description) -> Result<(), Error>;
	/// The peer's answer.
	fn answer(&self) -> impl Future<Output = Result<Description, Error>>;
	/// Carry one local candidate. It waits until the directory has accepted
	/// the offer.
	fn candidate(&self, candidate: &Candidate) -> impl Future<Output = Result<(), Error>>;
	/// The peer's next candidate, or `None` once the exchange has ended.
	fn next_candidate(&self) -> impl Future<Output = Result<Option<Candidate>, Error>>;
	/// End the exchange and tell the directory. A second close does nothing.
	fn close(&self) -> Result<(), Error>;
}
impl<P: Deadline + Tasks + Clone + 'static> Exchange for signaling::Exchange<P> {
	fn offer(&self, description: &Description) -> Result<(), Error> {
		signaling::Exchange::offer(self, description)
	}
	async fn answer(&self) -> Result<Description, Error> {
		signaling::Exchange::answer(self).await
	}
	async fn candidate(&self, candidate: &Candidate) -> Result<(), Error> {
		signaling::Exchange::candidate(self, candidate).await
	}
	async fn next_candidate(&self) -> Result<Option<Candidate>, Error> {
		signaling::Exchange::next_candidate(self).await
	}
	fn close(&self) -> Result<(), Error> {
		signaling::Exchange::close(self)
	}
}

/// Where a dial's exchange comes from. The embedding knows which live
/// directory each session key serves.
pub trait Exchanges {
	type Exchange: Exchange + 'static;
	/// The route an offer this peer answers came in on.
	type Reply: accepting::Reply + 'static;
	/// Open an exchange for a dial to `designator` through the directory the
	/// session `introducer` serves. `None` when no live directory is that
	/// session's.
	fn open(&self, introducer: &str, designator: &str) -> Result<Option<Self::Exchange>, Error>;
}

/// Signaling work that failed with no dial left to tell.
#[derive(Clone, Debug)]
pub struct Failure {
	/// The far peer's key, absent for an offer whose member registered none.
	pub designator: Option<String>,
	/// The key of the session whose directory carried the signaling, absent
	/// once that session has closed.
	pub introducer: Option<String>,
	pub stage: Stage,
	pub error: Error,
}
/// Which work failed.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Stage {
	/// A local candidate did not reach the directory.
	Candidate,
	/// The peer's candidate feed ended in an error, and the exchange was
	/// closed.
	Candidates,
	/// The exchange did not close.
	Close,
	/// An offer whose channel did not open in time was not given up.
	GiveUp,
	/// A refused offer's member was not told, so it waits out the deadline.
	Decline,
}
impl fmt::Display for Failure {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		let stage = match self.stage {
			Stage::Candidate => "a local candidate was not carried",
			Stage::Candidates => "the peer's candidates stopped",
			Stage::Close => "the exchange did not close",
			Stage::GiveUp => "a stalled offer was not given up",
			Stage::Decline => "a refused offer was not declined",
		};
		write!(
			f,
			"webrtc signaling to {} through {}: {stage}: {}",
			self.designator.as_deref().unwrap_or("a member with no Host key"),
			self.introducer.as_deref().unwrap_or("a closed directory session"),
			self.error
		)
	}
}

/// The binding's signaling authority over directory exchanges. Build it with
/// [`DirectorySignaling::new`] and hand it to the WebRTC provider.
///
/// Every dial and every accept is keyed by the exchange id the binding names,
/// so a dial to a member and that member's own offer run side by side.
pub struct DirectorySignaling<P: Tasks, X: Exchanges> {
	platform: P,
	exchanges: X,
	report: Rc<dyn Fn(Failure)>,
	dials: Rc<Dials<P::Task, X::Exchange>>,
	accepts: Rc<Accepts<X::Reply, P::Task>>,
	/// The offer being handed to the listener. Its answer goes out inside that
	/// call, which is where the accept learns its exchange id.
	answering: RefCell<Option<accepting::Offer<X::Reply>>>,
}
type Dials<T, E> = RefCell<HashMap<u64, Entry<T, E>>>;
enum Entry<T, E> {
	/// The exchange could not open. The offer returns this reason.
	Refused(glowcap::Error),
	Open(Dial<T, E>),
}
struct Dial<T, E> {
	introducer: String,
	designator: String,
	exchange: Rc<E>,
	/// Feeds the peer's candidates to the dial.
	pump: T,
	/// One task per local candidate, each waiting for the directory to accept
	/// the offer.
	sends: Vec<T>,
}
/// Names one dial on every failure report.
#[derive(Clone)]
struct Reporter {
	report: Rc<dyn Fn(Failure)>,
	designator: Option<String>,
	introducer: Option<String>,
}
impl Reporter {
	fn failed(&self, stage: Stage, error: Error) {
		(self.report)(Failure {
			designator: self.designator.clone(),
			introducer: self.introducer.clone(),
			stage,
			error,
		});
	}
}

impl<P: Tasks + 'static, X: Exchanges + 'static> DirectorySignaling<P, X> {
	/// `report` receives every [`Failure`], on the thread that steps the driver
	/// loop.
	pub fn new(platform: P, exchanges: X, report: impl Fn(Failure) + 'static) -> Rc<Self> {
		Rc::new(Self {
			platform,
			exchanges,
			report: Rc::new(report),
			dials: Rc::default(),
			accepts: Rc::default(),
			answering: RefCell::new(None),
		})
	}
	fn reporter(&self, designator: Option<&str>, introducer: Option<&str>) -> Reporter {
		Reporter {
			report: self.report.clone(),
			designator: designator.map(str::to_owned),
			introducer: introducer.map(str::to_owned),
		}
	}
	fn open(&self, target: Target<'_>, sink: Box<dyn Fn(String)>) -> Entry<P::Task, X::Exchange> {
		let Some(introducer) = target.introducer else {
			return Entry::Refused(refusal(
				"no session introduced this dial, so no directory can carry its signaling",
			));
		};
		let exchange = match self.exchanges.open(introducer, target.designator) {
			Ok(Some(exchange)) => Rc::new(exchange),
			Ok(None) => {
				return Entry::Refused(refusal(format!(
					"no live directory is served by the session {introducer} that introduced this dial"
				)));
			}
			Err(error) => return Entry::Refused(carry(error)),
		};
		let pump = self.platform.spawn(pump(
			exchange.clone(),
			sink,
			self.reporter(Some(target.designator), Some(introducer)),
		));
		Entry::Open(Dial {
			introducer: introducer.to_owned(),
			designator: target.designator.to_owned(),
			exchange,
			pump,
			sends: Vec::new(),
		})
	}
	/// The live exchange for a dial, or the reason there is none.
	fn exchange(&self, exchange: u64) -> glowcap::Result<Rc<X::Exchange>> {
		match self.dials.borrow().get(&exchange) {
			Some(Entry::Open(dial)) => Ok(dial.exchange.clone()),
			Some(Entry::Refused(error)) => Err(error.clone()),
			None => Err(unsubscribed()),
		}
	}
}

/// End a dial: stop its tasks, then close its exchange.
fn retire<T, E: Exchange>(dial: Dial<T, E>, reporter: &Reporter) {
	drop(dial.pump);
	drop(dial.sends);
	if let Err(error) = dial.exchange.close() {
		reporter.failed(Stage::Close, error);
	}
}

async fn pump<E: Exchange>(exchange: Rc<E>, sink: Box<dyn Fn(String)>, reporter: Reporter) {
	loop {
		match exchange.next_candidate().await {
			Ok(Some(candidate)) => sink(candidate.as_str().to_owned()),
			Ok(None) => return,
			Err(error) => {
				reporter.failed(Stage::Candidates, error);
				if let Err(error) = exchange.close() {
					reporter.failed(Stage::Close, error);
				}
				return;
			}
		}
	}
}

fn carry(error: Error) -> glowcap::Error {
	refusal(error.to_string())
}
fn unsubscribed() -> glowcap::Error {
	refusal("no signaling subscription is open for this dial")
}

impl<P: Tasks + 'static, X: Exchanges + 'static> SignalingAuthority for DirectorySignaling<P, X> {
	fn offer(
		&self,
		exchange: u64,
		_target: Target<'_>,
		sdp: &str,
	) -> Pin<Box<dyn Future<Output = glowcap::Result<String>>>> {
		let exchange = self.exchange(exchange);
		let sdp = sdp.to_owned();
		Box::pin(async move {
			let exchange = exchange?;
			let description = Description::parse(&sdp)
				.map_err(|error| refusal(format!("the offer is not a signaling description: {error}")))?;
			exchange.offer(&description).map_err(carry)?;
			let answer = exchange.answer().await.map_err(carry)?;
			Ok(answer.as_str().to_owned())
		})
	}
	fn answer(&self, exchange: u64, _target: Target<'_>, sdp: &str) -> glowcap::Result<()> {
		self.send_answer(exchange, sdp)
	}
	fn candidate(&self, exchange: u64, ice: &str) -> glowcap::Result<()> {
		let candidate =
			Candidate::parse(ice).map_err(|error| refusal(format!("the candidate is not signaling text: {error}")))?;
		if self.accepts.borrow().contains_key(&exchange) {
			return self.send_candidate(exchange, &candidate);
		}
		let mut dials = self.dials.borrow_mut();
		let dial = match dials.get_mut(&exchange) {
			Some(Entry::Open(dial)) => dial,
			Some(Entry::Refused(error)) => return Err(error.clone()),
			None => return Err(unsubscribed()),
		};
		let sent = dial.exchange.clone();
		let reporter = self.reporter(Some(&dial.designator), Some(&dial.introducer));
		dial.sends.push(self.platform.spawn(async move {
			if let Err(error) = sent.candidate(&candidate).await {
				reporter.failed(Stage::Candidate, error);
			}
		}));
		Ok(())
	}
	fn on_candidate(&self, exchange: u64, target: Target<'_>, sink: Box<dyn Fn(String)>) -> Box<dyn FnOnce()> {
		if self.accepts.borrow().contains_key(&exchange) {
			return self.subscribe_accept(exchange, sink);
		}
		let reporter = self.reporter(Some(target.designator), target.introducer);
		let entry = self.open(target, sink);
		let replaced = self.dials.borrow_mut().insert(exchange, entry);
		debug_assert!(replaced.is_none(), "the binding names each live exchange once");
		let dials: Weak<Dials<P::Task, X::Exchange>> = Rc::downgrade(&self.dials);
		Box::new(move || {
			let Some(dials) = dials.upgrade() else { return };
			let removed = dials.borrow_mut().remove(&exchange);
			if let Some(Entry::Open(dial)) = removed {
				retire(dial, &reporter);
			}
		})
	}
}
