//! The answering side over a fake directory route and a fake listener that
//! calls back into the authority the way the WebRTC library does.
use super::{Adapter, ROOM, bench, message, run, settle};
use crate::signaling::{
	Stage,
	accepting::{Answerer, Reply},
};
use glowcap::webrtc::{SignalingAuthority, Target, refusal};
use rooms_application::signaling::{Candidate, Description, Id, Reason};
use rooms_glowcap::client::Error;
use std::future::Future;
use std::{
	cell::{Cell, RefCell},
	rc::Rc,
	time::Duration,
};

const MEMBER: &str = "member-key";
/// The exchange id the fake listener gives its first accept.
const FIRST: u64 = 7;

/// The route an offer came in on: it records what goes back.
#[derive(Default)]
pub(super) struct FakeReply {
	answers: RefCell<Vec<(String, String)>>,
	candidates: RefCell<Vec<(String, String)>>,
	declines: RefCell<Vec<(String, String)>>,
	decline_fails: Cell<bool>,
}
impl Reply for FakeReply {
	fn answer(&self, id: &Id, answer: &Description) -> Result<(), Error> {
		self.answers
			.borrow_mut()
			.push((id.as_str().to_owned(), answer.as_str().to_owned()));
		Ok(())
	}
	fn candidate(&self, id: &Id, candidate: &Candidate) -> Result<(), Error> {
		self.candidates
			.borrow_mut()
			.push((id.as_str().to_owned(), candidate.as_str().to_owned()));
		Ok(())
	}
	fn decline(&self, id: &Id, reason: &Reason) -> Result<(), Error> {
		if self.decline_fails.get() {
			return Err(Error::Observation("the room is gone".into()));
		}
		self.declines
			.borrow_mut()
			.push((id.as_str().to_owned(), reason.as_str().to_owned()));
		Ok(())
	}
	fn directory(&self) -> Option<String> {
		Some(ROOM.to_owned())
	}
}

/// A listener that answers inside `provide_offer` and subscribes the
/// offerer's candidates, as the library does.
#[derive(Default)]
struct FakeListener {
	authority: RefCell<Option<Adapter>>,
	refuse: Cell<bool>,
	received: Rc<RefCell<Vec<String>>>,
	/// One subscription per accept, the latest last.
	dispose: RefCell<Vec<Box<dyn FnOnce()>>>,
	next: Cell<u64>,
	given_up: RefCell<Vec<u64>>,
	give_up_fails: Cell<bool>,
}
impl Answerer for FakeListener {
	fn provide_offer(&self, designator: &str, sdp: &str) -> glowcap::Result<u64> {
		if self.refuse.get() {
			return Err(refusal("the listener is full"));
		}
		let authority = self.authority.borrow().clone().expect("wired");
		let target = Target {
			designator,
			introducer: None,
		};
		let exchange = FIRST + self.next.get();
		authority.answer(exchange, target, &format!("answer to {sdp}"))?;
		self.next.set(self.next.get() + 1);
		let got = self.received.clone();
		let dispose = authority.on_candidate(exchange, target, Box::new(move |ice| got.borrow_mut().push(ice)));
		self.dispose.borrow_mut().push(dispose);
		Ok(exchange)
	}
	fn fail_exchange(&self, exchange: u64) -> glowcap::Result<()> {
		if self.give_up_fails.get() {
			return Err(refusal("no such accept"));
		}
		self.given_up.borrow_mut().push(exchange);
		Ok(())
	}
}
impl FakeListener {
	/// The latest accept's channel opened or it was given up: the library
	/// disposes its subscription.
	fn end(&self) {
		let dispose = self.dispose.borrow_mut().pop();
		if let Some(dispose) = dispose {
			dispose();
		}
	}
}

/// Run a scenario whose clock the test advances. The scenario deadline in
/// `run` would read that clock too.
async fn paused(scenario: impl Future<Output = ()>) {
	tokio::task::LocalSet::new().run_until(scenario).await
}

fn wired(signaling: &Adapter) -> Rc<FakeListener> {
	let listener = Rc::new(FakeListener::default());
	*listener.authority.borrow_mut() = Some(signaling.clone());
	listener
}
fn id(text: &str) -> Id {
	Id::parse(text).unwrap()
}
fn offer() -> Description {
	Description::parse("v=0 offer").unwrap()
}

#[tokio::test]
async fn an_offer_is_answered_through_the_route_it_came_in_on() {
	run(async {
		let bench = bench();
		let listener = wired(&bench.signaling);
		let reply = Rc::new(FakeReply::default());
		bench
			.signaling
			.offered(&listener, reply.clone(), id("x1"), Some(id(MEMBER)), &offer())
			.unwrap();
		assert_eq!(
			reply.answers.borrow().as_slice(),
			[("x1".to_owned(), "answer to v=0 offer".to_owned())]
		);

		// Local candidates go back under the offer's id, and the member's
		// reach the listener.
		bench.signaling.candidate(FIRST, "local ice").unwrap();
		assert_eq!(
			reply.candidates.borrow().as_slice(),
			[("x1".to_owned(), "local ice".to_owned())]
		);
		bench
			.signaling
			.far_candidate(&id("x1"), &Candidate::parse("far ice").unwrap());
		assert_eq!(listener.received.borrow().as_slice(), ["far ice"]);

		// Once the accept ends, a late candidate is dropped and the member
		// may offer again.
		listener.end();
		bench
			.signaling
			.far_candidate(&id("x1"), &Candidate::parse("late ice").unwrap());
		assert_eq!(listener.received.borrow().len(), 1);
		assert!(bench.signaling.candidate(FIRST, "after").is_err());
		bench
			.signaling
			.offered(&listener, reply, id("x2"), Some(id(MEMBER)), &offer())
			.unwrap();
		assert!(bench.failures.borrow().is_empty());
	})
	.await
}

#[tokio::test]
async fn an_offer_naming_nobody_is_declined() {
	run(async {
		let bench = bench();
		let listener = wired(&bench.signaling);
		let reply = Rc::new(FakeReply::default());
		let unproved = bench
			.signaling
			.offered(&listener, reply.clone(), id("x1"), None, &offer())
			.unwrap_err();
		assert!(message(unproved).contains("registered no Host key"));
		assert!(reply.answers.borrow().is_empty());
		let declines = reply.declines.borrow();
		assert_eq!(declines.len(), 1);
		assert_eq!(declines[0].0, "x1");
		assert!(declines[0].1.contains("registered no Host key"));
	})
	.await
}

#[tokio::test]
async fn a_dial_and_offers_with_one_member_run_side_by_side() {
	run(async {
		let bench = bench();
		let listener = wired(&bench.signaling);
		let reply = Rc::new(FakeReply::default());

		// This peer dials the member while the member dials this peer, twice.
		let dial = Target {
			designator: MEMBER,
			introducer: Some(ROOM),
		};
		let dispose = bench.signaling.on_candidate(1, dial, Box::new(|_| {}));
		for offer_id in ["x1", "x2"] {
			bench
				.signaling
				.offered(&listener, reply.clone(), id(offer_id), Some(id(MEMBER)), &offer())
				.unwrap();
		}
		assert_eq!(reply.answers.borrow().len(), 2);

		// Each local candidate goes out on its own exchange's route.
		bench.signaling.candidate(FIRST + 1, "second ice").unwrap();
		bench.signaling.candidate(FIRST, "first ice").unwrap();
		assert_eq!(
			reply.candidates.borrow().as_slice(),
			[
				("x2".to_owned(), "second ice".to_owned()),
				("x1".to_owned(), "first ice".to_owned())
			]
		);
		// The dial's candidate waits for its own directory exchange instead.
		bench.signaling.candidate(1, "dial ice").unwrap();
		settle().await;
		assert_eq!(reply.candidates.borrow().len(), 2);
		assert_eq!(bench.room.opened.borrow().len(), 1);
		dispose();
		assert!(bench.failures.borrow().is_empty());
	})
	.await
}

#[tokio::test]
async fn a_refused_offer_leaves_nothing_behind() {
	run(async {
		let bench = bench();
		let listener = wired(&bench.signaling);
		let reply = Rc::new(FakeReply::default());
		listener.refuse.set(true);
		assert!(
			bench
				.signaling
				.offered(&listener, reply.clone(), id("x1"), Some(id(MEMBER)), &offer())
				.is_err()
		);
		assert!(reply.declines.borrow()[0].1.contains("the listener is full"));
		// A decline the route refuses is reported, and the refusal still returns.
		reply.decline_fails.set(true);
		let refused = bench
			.signaling
			.offered(&listener, reply.clone(), id("x2"), Some(id(MEMBER)), &offer())
			.unwrap_err();
		assert!(message(refused).contains("the listener is full"));
		{
			let failures = bench.failures.borrow();
			assert_eq!(failures.len(), 1);
			assert_eq!(failures[0].stage, Stage::Decline);
			assert_eq!(failures[0].designator.as_deref(), Some(MEMBER));
		}
		reply.decline_fails.set(false);
		listener.refuse.set(false);
		bench
			.signaling
			.offered(&listener, reply, id("x3"), Some(id(MEMBER)), &offer())
			.unwrap();
	})
	.await
}

#[tokio::test(start_paused = true)]
async fn a_stalled_offer_is_given_up_at_the_signaling_deadline() {
	paused(async {
		let bench = bench();
		let listener = wired(&bench.signaling);
		bench
			.signaling
			.offered(
				&listener,
				Rc::new(FakeReply::default()),
				id("x1"),
				Some(id(MEMBER)),
				&offer(),
			)
			.unwrap();
		settle().await;
		tokio::time::advance(Duration::from_millis(rooms_application::signaling::TIMEOUT_MS)).await;
		settle().await;
		assert_eq!(listener.given_up.borrow().as_slice(), [7]);

		// A give-up the listener refuses is reported, not dropped.
		listener.end();
		listener.give_up_fails.set(true);
		bench
			.signaling
			.offered(
				&listener,
				Rc::new(FakeReply::default()),
				id("x2"),
				Some(id(MEMBER)),
				&offer(),
			)
			.unwrap();
		settle().await;
		tokio::time::advance(Duration::from_millis(rooms_application::signaling::TIMEOUT_MS)).await;
		settle().await;
		let failures = bench.failures.borrow();
		assert_eq!(failures.len(), 1);
		assert_eq!(failures[0].stage, Stage::GiveUp);
		assert_eq!(failures[0].designator.as_deref(), Some(MEMBER));
	})
	.await
}

#[tokio::test(start_paused = true)]
async fn an_accept_that_opens_is_never_given_up() {
	paused(async {
		let bench = bench();
		let listener = wired(&bench.signaling);
		bench
			.signaling
			.offered(
				&listener,
				Rc::new(FakeReply::default()),
				id("x1"),
				Some(id(MEMBER)),
				&offer(),
			)
			.unwrap();
		listener.end();
		tokio::time::advance(Duration::from_millis(rooms_application::signaling::TIMEOUT_MS)).await;
		settle().await;
		assert!(listener.given_up.borrow().is_empty());
	})
	.await
}
