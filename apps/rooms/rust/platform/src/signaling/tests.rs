//! The directory signaling adapter over a fake exchange.
mod accepting;
use super::{DirectorySignaling, Exchange, Exchanges, Failure, Stage};
use crate::HostPlatform;
use glowcap::webrtc::{SignalingAuthority, Target};
use rooms_application::signaling::{Candidate, Description, Error as Signal};
use rooms_glowcap::client::Error;
use std::{
	cell::{Cell, RefCell},
	collections::{HashMap, VecDeque},
	future::Future,
	rc::Rc,
	task::Poll,
	time::Duration,
};
use tokio::sync::Notify;

/// One exchange the test drives by hand: it accepts the offer, answers, and
/// delivers the peer's candidates when told to.
#[derive(Default)]
struct FakeExchange {
	offered: RefCell<Option<Description>>,
	accepted: Cell<bool>,
	answer: RefCell<Option<Description>>,
	sent: RefCell<Vec<String>>,
	incoming: RefCell<VecDeque<Result<Option<Candidate>, Error>>>,
	closed: Cell<u32>,
	wake: Notify,
}
impl FakeExchange {
	fn accept(&self) {
		self.accepted.set(true);
		self.wake.notify_waiters();
	}
	fn answer_with(&self, text: &str) {
		*self.answer.borrow_mut() = Some(Description::parse(text).unwrap());
		self.wake.notify_waiters();
	}
	fn arrive(&self, event: Result<Option<Candidate>, Error>) {
		self.incoming.borrow_mut().push_back(event);
		self.wake.notify_waiters();
	}
	fn ended(&self) -> bool {
		self.closed.get() > 0
	}
	async fn until<T>(&self, ready: impl Fn(&Self) -> Option<T>) -> T {
		loop {
			let notified = self.wake.notified();
			if let Some(value) = ready(self) {
				return value;
			}
			notified.await;
		}
	}
}
fn ended() -> Error {
	Error::Signaling(Signal::Ended)
}
impl Exchange for Rc<FakeExchange> {
	fn offer(&self, description: &Description) -> Result<(), Error> {
		if self.ended() {
			return Err(ended());
		}
		if self.offered.borrow().is_some() {
			return Err(Error::Signaling(Signal::Duplicate));
		}
		*self.offered.borrow_mut() = Some(description.clone());
		Ok(())
	}
	async fn answer(&self) -> Result<Description, Error> {
		self.until(|x| {
			if x.ended() {
				return Some(Err(ended()));
			}
			x.answer.borrow().clone().map(Ok)
		})
		.await
	}
	async fn candidate(&self, candidate: &Candidate) -> Result<(), Error> {
		self.until(|x| {
			if x.ended() {
				return Some(Err(ended()));
			}
			x.accepted.get().then_some(Ok(()))
		})
		.await?;
		self.sent.borrow_mut().push(candidate.as_str().to_owned());
		Ok(())
	}
	async fn next_candidate(&self) -> Result<Option<Candidate>, Error> {
		self.until(|x| {
			if x.ended() {
				return Some(Ok(None));
			}
			x.incoming.borrow_mut().pop_front()
		})
		.await
	}
	fn close(&self) -> Result<(), Error> {
		self.closed.set(self.closed.get() + 1);
		self.wake.notify_waiters();
		Ok(())
	}
}

/// The live directories, keyed by the session that serves each.
#[derive(Default)]
struct Directories {
	served: RefCell<HashMap<String, Rc<Directory>>>,
}
#[derive(Default)]
struct Directory {
	opened: RefCell<Vec<(String, Rc<FakeExchange>)>>,
	refuse: Cell<bool>,
}
impl Exchanges for Rc<Directories> {
	type Exchange = Rc<FakeExchange>;
	type Reply = accepting::FakeReply;
	fn open(&self, introducer: &str, designator: &str) -> Result<Option<Rc<FakeExchange>>, Error> {
		let Some(directory) = self.served.borrow().get(introducer).cloned() else {
			return Ok(None);
		};
		if directory.refuse.get() {
			return Err(Error::Signaling(Signal::Full));
		}
		let exchange = Rc::new(FakeExchange::default());
		directory
			.opened
			.borrow_mut()
			.push((designator.to_owned(), exchange.clone()));
		Ok(Some(exchange))
	}
}

type Adapter = Rc<DirectorySignaling<HostPlatform, Rc<Directories>>>;
struct Bench {
	signaling: Adapter,
	room: Rc<Directory>,
	failures: Rc<RefCell<Vec<Failure>>>,
}
const ROOM: &str = "room-key";
const PEER: Target<'static> = Target {
	designator: "browser-key",
	introducer: Some(ROOM),
};
fn bench() -> Bench {
	let directories = Rc::new(Directories::default());
	let room = Rc::new(Directory::default());
	directories.served.borrow_mut().insert(ROOM.to_owned(), room.clone());
	let failures = Rc::new(RefCell::new(Vec::new()));
	let sink = failures.clone();
	let signaling = DirectorySignaling::new(HostPlatform, directories, move |failure| {
		sink.borrow_mut().push(failure)
	});
	Bench {
		signaling,
		room,
		failures,
	}
}
/// Let spawned tasks run to their next wait.
async fn settle() {
	for _ in 0..8 {
		tokio::task::yield_now().await;
	}
}
fn pending<T>(future: &mut (impl Future<Output = T> + Unpin)) -> bool {
	let waker = std::task::Waker::noop();
	let mut cx = std::task::Context::from_waker(waker);
	matches!(std::pin::Pin::new(future).poll(&mut cx), Poll::Pending)
}
async fn run(scenario: impl Future<Output = ()>) {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(10), scenario)
				.await
				.expect("signaling scenario deadline");
		})
		.await
}
fn message(error: glowcap::Error) -> String {
	error.message().unwrap_or_default().to_owned()
}

#[tokio::test]
async fn a_handoff_dial_signals_through_the_introducing_directory() {
	run(async {
		let Bench {
			signaling,
			room,
			failures,
		} = bench();
		let received = Rc::new(RefCell::new(Vec::new()));
		let got = received.clone();
		let dispose = signaling.on_candidate(1, PEER, Box::new(move |ice| got.borrow_mut().push(ice)));
		let (designator, exchange) = room.opened.borrow()[0].clone();
		assert_eq!(designator, PEER.designator);

		// A candidate before the offer waits for the directory to accept it.
		signaling.candidate(1, "early ice").unwrap();
		settle().await;
		assert!(exchange.sent.borrow().is_empty());
		let mut answer = Box::pin(signaling.offer(1, PEER, "offer sdp"));
		assert!(pending(&mut answer));
		settle().await;
		assert_eq!(exchange.offered.borrow().as_ref().unwrap().as_str(), "offer sdp");
		exchange.accept();
		settle().await;
		assert_eq!(*exchange.sent.borrow(), ["early ice"]);
		signaling.candidate(1, "late ice").unwrap();
		settle().await;
		assert_eq!(*exchange.sent.borrow(), ["early ice", "late ice"]);

		// The peer's candidates reach the dial, then its answer does.
		exchange.arrive(Ok(Some(Candidate::parse("remote ice").unwrap())));
		settle().await;
		assert_eq!(*received.borrow(), ["remote ice"]);
		assert!(pending(&mut answer));
		exchange.answer_with("answer sdp");
		assert_eq!(answer.await.unwrap(), "answer sdp");

		// Ending the subscription closes the exchange and stops the pump.
		dispose();
		assert_eq!(exchange.closed.get(), 1);
		exchange.arrive(Ok(Some(Candidate::parse("too late").unwrap())));
		settle().await;
		assert_eq!(received.borrow().len(), 1);
		assert!(message(signaling.offer(1, PEER, "again").await.unwrap_err()).contains("subscription"));
		assert!(failures.borrow().is_empty());

		// The next dial to the same peer opens its own exchange.
		let dispose = signaling.on_candidate(2, PEER, Box::new(|_| {}));
		assert_eq!(room.opened.borrow().len(), 2);
		dispose();
		assert_eq!(room.opened.borrow()[1].1.closed.get(), 1);
	})
	.await;
}

#[tokio::test]
async fn a_dial_the_directory_cannot_carry_is_refused_with_its_reason() {
	run(async {
		let Bench {
			signaling,
			room,
			failures,
		} = bench();
		let own = Target {
			designator: "browser-key",
			introducer: None,
		};
		let dispose = signaling.on_candidate(1, own, Box::new(|_| {}));
		assert!(message(signaling.offer(1, own, "offer").await.unwrap_err()).contains("no session introduced"));
		assert!(message(signaling.candidate(1, "ice").unwrap_err()).contains("no session introduced"));
		dispose();
		let stranger = Target {
			designator: "browser-key",
			introducer: Some("nobody"),
		};
		let dispose = signaling.on_candidate(2, stranger, Box::new(|_| {}));
		assert!(message(signaling.offer(2, stranger, "offer").await.unwrap_err()).contains("nobody"));
		dispose();
		assert!(room.opened.borrow().is_empty());

		// The directory refused the exchange.
		room.refuse.set(true);
		let dispose = signaling.on_candidate(3, PEER, Box::new(|_| {}));
		assert!(message(signaling.offer(3, PEER, "offer").await.unwrap_err()).contains(&Signal::Full.to_string()));
		dispose();
		room.refuse.set(false);

		// Text the signaling messages cannot carry, and an offer with no
		// subscription, fail before anything is sent.
		let dispose = signaling.on_candidate(4, PEER, Box::new(|_| {}));
		assert!(message(signaling.offer(4, PEER, "").await.unwrap_err()).contains("description"));
		assert!(message(signaling.candidate(4, "").unwrap_err()).contains("candidate"));
		assert!(room.opened.borrow()[0].1.offered.borrow().is_none());
		assert!(message(signaling.offer(5, PEER, "offer").await.unwrap_err()).contains("subscription"));

		// A second dial to the same peer, as when both peers dial at once,
		// opens its own exchange and leaves the first alone.
		let second = signaling.on_candidate(5, PEER, Box::new(|_| {}));
		assert_eq!(room.opened.borrow().len(), 2);
		second();
		assert_eq!(room.opened.borrow()[1].1.closed.get(), 1);
		assert_eq!(room.opened.borrow()[0].1.closed.get(), 0);
		dispose();
		assert_eq!(room.opened.borrow()[0].1.closed.get(), 1);
		assert!(failures.borrow().is_empty());
	})
	.await;
}

#[tokio::test]
async fn a_failed_candidate_pump_closes_its_exchange_and_reports() {
	run(async {
		let Bench {
			signaling,
			room,
			failures,
		} = bench();
		let dispose = signaling.on_candidate(1, PEER, Box::new(|_| {}));
		let exchange = room.opened.borrow()[0].1.clone();
		let mut answer = Box::pin(signaling.offer(1, PEER, "offer sdp"));
		assert!(pending(&mut answer));
		exchange.arrive(Err(Error::Timeout("the signaling exchange timed out")));
		settle().await;
		assert_eq!(exchange.closed.get(), 1);
		{
			let failures = failures.borrow();
			assert_eq!(failures.len(), 1);
			assert_eq!(failures[0].stage, Stage::Candidates);
			assert_eq!(failures[0].designator.as_deref(), Some(PEER.designator));
			assert_eq!(failures[0].introducer.as_deref(), Some(ROOM));
			let shown = failures[0].to_string();
			assert!(shown.contains("browser-key through room-key"), "{shown}");
			assert!(shown.contains("timed out"), "{shown}");
		}
		assert!(message(answer.await.unwrap_err()).contains(&Signal::Ended.to_string()));

		// A candidate after the close fails in its own task and is reported.
		signaling.candidate(1, "ice").unwrap();
		settle().await;
		assert_eq!(failures.borrow().len(), 2);
		assert_eq!(failures.borrow()[1].stage, Stage::Candidate);
		dispose();
		assert_eq!(exchange.closed.get(), 2);
		assert_eq!(failures.borrow().len(), 2);
	})
	.await;
}
