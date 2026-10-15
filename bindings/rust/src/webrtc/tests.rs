//! Hermetic checks of the signaling trampolines and the offer verb. The live
//! proofs through the C provider are in `live`.

use std::cell::{Cell, RefCell};
use std::future::Future;
use std::pin::Pin;
use std::rc::Rc;
use std::time::Duration;

use tokio::sync::oneshot;
use tokio::task::LocalSet;

use super::netlayer::{
	State, Verbs, done_trampoline, send_answer_trampoline, send_candidate_trampoline, send_offer_trampoline,
};
use super::{SignalingAuthority, Target, locator};
use crate::{Error, Result, sys};

mod live;

const DEADLINE: Duration = Duration::from_secs(10);

/// The exchange id the fake library gives the one accept a test starts: the
/// accept bit the C library sets, over its first counter value.
const ACCEPT: u64 = (1 << 63) | 1;

/// How the recorder answers an offer.
enum Offer {
	/// Never answers, so the exchange stays open until `done`.
	Pending,
	/// Fails with an I/O error.
	Fail,
	/// Panics inside the future.
	Panic,
	/// Answers with the text the test sends on the channel.
	Await(RefCell<Option<oneshot::Receiver<String>>>),
}

/// Records what the trampolines hand the application.
/// One offer the netlayer sent through the authority.
#[derive(Debug, PartialEq)]
struct Sent {
	exchange: u64,
	designator: String,
	introducer: Option<String>,
	sdp: String,
}
fn sent(exchange: u64, introducer: Option<&str>) -> Sent {
	Sent {
		exchange,
		designator: "peer".to_string(),
		introducer: introducer.map(str::to_string),
		sdp: "sdp".to_string(),
	}
}

struct Recorder {
	offers: RefCell<Vec<Sent>>,
	answers: RefCell<Vec<(u64, String, String)>>,
	candidates: RefCell<Vec<(u64, String)>>,
	subscribed: Cell<usize>,
	disposed: Rc<Cell<usize>>,
	reject_answers: Cell<bool>,
	reject_candidates: Cell<bool>,
	/// A loopback authority: each local candidate hands an offer back to this
	/// netlayer from inside the callback.
	loopback: RefCell<Option<std::rc::Weak<State>>>,
	offer: Offer,
}

impl Recorder {
	fn new(offer: Offer) -> Rc<Recorder> {
		Rc::new(Recorder {
			offers: RefCell::new(Vec::new()),
			answers: RefCell::new(Vec::new()),
			candidates: RefCell::new(Vec::new()),
			subscribed: Cell::new(0),
			disposed: Rc::new(Cell::new(0)),
			reject_answers: Cell::new(false),
			reject_candidates: Cell::new(false),
			loopback: RefCell::new(None),
			offer,
		})
	}
}

impl SignalingAuthority for Recorder {
	fn offer(&self, exchange: u64, target: Target<'_>, sdp: &str) -> Pin<Box<dyn Future<Output = Result<String>>>> {
		self.offers.borrow_mut().push(Sent {
			exchange,
			designator: target.designator.to_string(),
			introducer: target.introducer.map(str::to_string),
			sdp: sdp.to_string(),
		});
		match &self.offer {
			Offer::Pending => Box::pin(std::future::pending()),
			Offer::Fail => Box::pin(std::future::ready(Err(Error::from_code(sys::ERR_IO)))),
			Offer::Panic => Box::pin(async { panic!("the offer carrier broke") }),
			Offer::Await(answer) => {
				let answer = answer.borrow_mut().take().expect("one offer per recorder");
				Box::pin(async move { answer.await.map_err(|_| Error::from_code(sys::ERR_IO)) })
			}
		}
	}

	fn answer(&self, exchange: u64, target: Target<'_>, sdp: &str) -> Result<()> {
		assert_eq!(target.introducer, None, "an accept has no introducer");
		self.answers
			.borrow_mut()
			.push((exchange, target.designator.to_string(), sdp.to_string()));
		if self.reject_answers.get() {
			return Err(Error::from_code(sys::ERR_IO));
		}
		Ok(())
	}

	fn candidate(&self, exchange: u64, ice: &str) -> Result<()> {
		self.candidates.borrow_mut().push((exchange, ice.to_string()));
		if self.reject_candidates.get() {
			return Err(Error::from_code(sys::ERR_IO));
		}
		if let Some(state) = self.loopback.borrow().as_ref().and_then(std::rc::Weak::upgrade) {
			state.provide_offer("loopback", "offer-sdp")?;
		}
		Ok(())
	}

	fn on_candidate(&self, _exchange: u64, _target: Target<'_>, _sink: Box<dyn Fn(String)>) -> Box<dyn FnOnce()> {
		self.subscribed.set(self.subscribed.get() + 1);
		let disposed = Rc::clone(&self.disposed);
		Box::new(move || disposed.set(disposed.get() + 1))
	}
}

/// Records the verbs the exchanges hand the netlayer, and answers each with
/// `code`.
struct FakeVerbs {
	calls: RefCell<Vec<(&'static str, u64)>>,
	code: Cell<i32>,
	next_accept: Cell<u64>,
}

impl FakeVerbs {
	fn new() -> Rc<FakeVerbs> {
		Rc::new(FakeVerbs {
			calls: RefCell::new(Vec::new()),
			code: Cell::new(sys::OK),
			next_accept: Cell::new(ACCEPT),
		})
	}

	fn note(&self, verb: &'static str, exchange: u64) -> i32 {
		self.calls.borrow_mut().push((verb, exchange));
		self.code.get()
	}
}

impl Verbs for FakeVerbs {
	unsafe fn provide_offer(
		&self,
		_netlayer: *mut crate::sys::webrtc::GlowcapWebrtcNetlayer,
		_designator: &str,
		_sdp: &str,
		out_exchange: &mut u64,
	) -> i32 {
		let exchange = self.next_accept.get();
		self.next_accept.set(exchange + 1);
		*out_exchange = exchange;
		self.note("offer", exchange)
	}

	unsafe fn provide_answer(
		&self,
		_netlayer: *mut crate::sys::webrtc::GlowcapWebrtcNetlayer,
		exchange: u64,
		_sdp: &str,
	) -> i32 {
		self.note("answer", exchange)
	}

	unsafe fn provide_candidate(
		&self,
		_netlayer: *mut crate::sys::webrtc::GlowcapWebrtcNetlayer,
		exchange: u64,
		_ice: &str,
	) -> i32 {
		self.note("candidate", exchange)
	}

	unsafe fn fail_exchange(&self, _netlayer: *mut crate::sys::webrtc::GlowcapWebrtcNetlayer, exchange: u64) -> i32 {
		self.note("fail", exchange)
	}
}

/// A state over a recorder and fake verbs.
fn state(offer: Offer) -> (Rc<Recorder>, Rc<FakeVerbs>, Rc<State>) {
	let recorder = Recorder::new(offer);
	let verbs = FakeVerbs::new();
	let state = State::for_test(
		Rc::clone(&recorder) as Rc<dyn SignalingAuthority>,
		Rc::clone(&verbs) as Rc<dyn Verbs>,
	);
	(recorder, verbs, state)
}

fn offer(ctx: *mut std::ffi::c_void, exchange: u64, designator: &str, sdp: &str) -> i32 {
	offer_introduced(ctx, exchange, designator, None, sdp)
}

fn offer_introduced(
	ctx: *mut std::ffi::c_void,
	exchange: u64,
	designator: &str,
	introducer: Option<&str>,
	sdp: &str,
) -> i32 {
	// SAFETY: `ctx` is the pointer of a live `State` the test owns. Every view borrows a `&str` that outlives the call,
	// and a missing introducer is the null pointer with a zero length the C library passes.
	unsafe {
		send_offer_trampoline(
			ctx,
			exchange,
			designator.as_ptr(),
			designator.len(),
			introducer.map_or(std::ptr::null(), str::as_ptr),
			introducer.map_or(0, str::len),
			sdp.as_ptr(),
			sdp.len(),
		)
	}
}

fn answer(ctx: *mut std::ffi::c_void, exchange: u64, designator: &str, sdp: &str) -> i32 {
	// SAFETY: `ctx` is the pointer of a live `State` the test owns, and both views borrow `&str`s that outlive the call.
	unsafe {
		send_answer_trampoline(
			ctx,
			exchange,
			designator.as_ptr(),
			designator.len(),
			sdp.as_ptr(),
			sdp.len(),
		)
	}
}

fn candidate(ctx: *mut std::ffi::c_void, exchange: u64, ice: &str) -> i32 {
	// SAFETY: `ctx` is the pointer of a live `State` the test owns, and `ice` is a `&str` that outlives the call.
	unsafe { send_candidate_trampoline(ctx, exchange, ice.as_ptr(), ice.len()) }
}

fn done(ctx: *mut std::ffi::c_void, exchange: u64) {
	// SAFETY: `ctx` is the pointer of a live `State` the test owns.
	unsafe { done_trampoline(ctx, exchange) }
}

/// Hold the process-wide failure record for one test, emptied, so another
/// test cannot claim what this one records.
fn failure_record() -> std::sync::MutexGuard<'static, ()> {
	let serial = crate::runtime_failure::RUNTIME_FAILURE_TEST_LOCK
		.lock()
		.unwrap_or_else(std::sync::PoisonError::into_inner);
	crate::take_runtime_failures();
	serial
}

/// Whether a binding failure for `operation` was recorded since the record was
/// taken.
fn recorded(operation: &str) -> bool {
	crate::take_runtime_failures()
		.iter()
		.any(|failure| failure.operation == operation)
}

/// Run `body` on a `LocalSet` in a fresh single-thread runtime, under the
/// deadline every dial test keeps. The tests are synchronous so one may hold
/// the failure record's lock throughout.
fn on_local_set<F: Future<Output = ()>>(body: F) {
	let runtime = tokio::runtime::Builder::new_current_thread()
		.enable_time()
		.build()
		.unwrap();
	runtime.block_on(LocalSet::new().run_until(async { tokio::time::timeout(DEADLINE, body).await.unwrap() }));
}

#[test]
fn locator_matches_the_parsed_uri_form() {
	let uri = crate::uri::format_peer_locator("webrtc", "abcd", "").unwrap();
	assert_eq!(locator("abcd"), crate::uri::parse_locator(&uri).unwrap());
}

#[test]
fn a_handoff_dial_names_its_introducer_to_every_signaling_call() {
	let (recorder, _verbs, state) = state(Offer::Pending);
	let ctx = state.ctx();
	on_local_set(async {
		assert_eq!(offer_introduced(ctx, 2, "peer", Some("directory"), "sdp"), 0);
		tokio::task::yield_now().await;
		assert_eq!(*recorder.offers.borrow(), [sent(2, Some("directory"))]);
		let ice = "{\"candidate\":\"c\"}";
		assert_eq!(candidate(ctx, 2, ice), 0);
		assert_eq!(*recorder.candidates.borrow(), [(2, ice.to_string())]);
		done(ctx, 2);
	});
}

#[test]
fn trampolines_carry_one_exchange_from_offer_to_done() {
	let (recorder, verbs, state) = state(Offer::Pending);
	let ctx = state.ctx();
	on_local_set(async {
		assert_eq!(offer(ctx, 7, "peer", "sdp"), 0);
		assert_eq!(offer(ctx, 7, "peer", "sdp"), 1, "a live exchange id is refused");
		tokio::task::yield_now().await;
		assert_eq!(*recorder.offers.borrow(), [sent(7, None)]);
		assert_eq!(recorder.subscribed.get(), 1);

		let ice = "{\"candidate\":\"c\"}";
		assert_eq!(candidate(ctx, 7, ice), 0);
		assert_eq!(*recorder.candidates.borrow(), [(7, ice.to_string())]);

		done(ctx, 7);
		assert_eq!(recorder.disposed.get(), 1);
		assert_eq!(state.open_exchanges(), 0);
		done(ctx, 7);
		assert_eq!(recorder.disposed.get(), 1, "a second done disposes nothing");
		assert_eq!(offer(ctx, 7, "peer", "sdp"), 0, "the id is free again after done");
		done(ctx, 7);
		assert!(
			verbs.calls.borrow().is_empty(),
			"a pending offer hands the netlayer nothing"
		);
	});
}

#[test]
fn a_dial_outside_a_local_set_is_refused_and_unsubscribed() {
	let _record = failure_record();
	let (recorder, _verbs, state) = state(Offer::Pending);
	assert_eq!(offer(state.ctx(), 1, "peer", "sdp"), 1);
	assert_eq!(recorder.disposed.get(), 1);
	assert_eq!(state.open_exchanges(), 0);
}

#[test]
fn a_rejected_candidate_is_retained_and_refuses_the_dial_by_its_return() {
	let _record = failure_record();
	let (recorder, verbs, state) = state(Offer::Pending);
	recorder.reject_candidates.set(true);
	let ctx = state.ctx();
	on_local_set(async {
		assert_eq!(offer(ctx, 3, "peer", "sdp"), 0);
		assert_eq!(candidate(ctx, 3, "{}"), 1, "the callback's return fails the dial");
		assert!(recorded("webrtc-signaling-candidate"));
		assert!(
			verbs.calls.borrow().is_empty(),
			"no verb is called from inside the driver's step"
		);
		done(ctx, 3);
	});
}

#[test]
fn a_failing_offer_is_retained_and_gives_the_dial_up_once() {
	let _record = failure_record();
	let (_recorder, verbs, state) = state(Offer::Fail);
	let ctx = state.ctx();
	on_local_set(async {
		assert_eq!(offer(ctx, 4, "peer", "sdp"), 0);
		for _ in 0..4 {
			tokio::task::yield_now().await;
		}
		assert!(recorded("webrtc-signaling-offer"));
		assert_eq!(*verbs.calls.borrow(), [("fail", 4)]);
		assert_eq!(state.open_exchanges(), 1, "the exchange stays until done");
		done(ctx, 4);
		assert_eq!(state.open_exchanges(), 0);
	});
}

#[test]
fn a_panicking_offer_is_retained_and_gives_the_dial_up() {
	let _record = failure_record();
	let (_recorder, verbs, state) = state(Offer::Panic);
	let ctx = state.ctx();
	on_local_set(async {
		assert_eq!(offer(ctx, 5, "peer", "sdp"), 0);
		for _ in 0..4 {
			tokio::task::yield_now().await;
		}
		assert!(recorded("webrtc-signaling-offer"));
		assert_eq!(*verbs.calls.borrow(), [("fail", 5)]);
		done(ctx, 5);
	});
}

#[test]
fn an_answer_after_done_provides_nothing() {
	let (send, receive) = oneshot::channel();
	let (_recorder, verbs, state) = state(Offer::Await(RefCell::new(Some(receive))));
	let ctx = state.ctx();
	on_local_set(async {
		assert_eq!(offer(ctx, 6, "peer", "sdp"), 0);
		tokio::task::yield_now().await;
		done(ctx, 6);
		send.send("answer".to_string()).ok();
		for _ in 0..4 {
			tokio::task::yield_now().await;
		}
		assert!(verbs.calls.borrow().is_empty());
	});
}

#[test]
fn an_answer_in_time_is_provided_to_its_exchange() {
	let (send, receive) = oneshot::channel();
	let (_recorder, verbs, state) = state(Offer::Await(RefCell::new(Some(receive))));
	let ctx = state.ctx();
	on_local_set(async {
		assert_eq!(offer(ctx, 8, "peer", "sdp"), 0);
		send.send("answer".to_string()).ok();
		for _ in 0..4 {
			tokio::task::yield_now().await;
		}
		assert_eq!(*verbs.calls.borrow(), [("answer", 8)]);
		done(ctx, 8);
	});
}

#[test]
fn an_answer_the_netlayer_refuses_is_retained() {
	let _record = failure_record();
	let (send, receive) = oneshot::channel();
	let (_recorder, verbs, state) = state(Offer::Await(RefCell::new(Some(receive))));
	verbs.code.set(sys::ERR_IO);
	let ctx = state.ctx();
	on_local_set(async {
		assert_eq!(offer(ctx, 9, "peer", "sdp"), 0);
		send.send("answer".to_string()).ok();
		for _ in 0..4 {
			tokio::task::yield_now().await;
		}
		assert_eq!(*verbs.calls.borrow(), [("answer", 9)]);
		assert!(recorded("webrtc-provide-answer"));
		done(ctx, 9);
	});
}

#[test]
fn an_inbound_offers_answer_is_carried_to_its_offerer() {
	let (recorder, _verbs, state) = state(Offer::Pending);
	assert_eq!(answer(state.ctx(), ACCEPT, "offerer", "answer-sdp"), 0);
	assert_eq!(
		*recorder.answers.borrow(),
		[(ACCEPT, "offerer".to_string(), "answer-sdp".to_string())]
	);
}

#[test]
fn an_answer_the_authority_cannot_carry_refuses_the_offer_and_is_retained() {
	let _record = failure_record();
	let (recorder, _verbs, state) = state(Offer::Pending);
	recorder.reject_answers.set(true);
	assert_eq!(answer(state.ctx(), ACCEPT, "offerer", "answer-sdp"), 1);
	assert!(recorded("webrtc-signaling-answer"));
}

#[test]
fn an_accepted_offer_subscribes_the_offerer_until_done() {
	let (recorder, verbs, state) = state(Offer::Pending);
	let ctx = state.ctx();
	assert_eq!(state.provide_offer("offerer", "offer-sdp").unwrap(), ACCEPT);
	assert_eq!(*verbs.calls.borrow(), [("offer", ACCEPT)]);
	assert_eq!(recorder.subscribed.get(), 1);
	assert_eq!(state.open_exchanges(), 1);

	let ice = "{\"candidate\":\"c\"}";
	assert_eq!(candidate(ctx, ACCEPT, ice), 0);
	assert_eq!(*recorder.candidates.borrow(), [(ACCEPT, ice.to_string())]);

	done(ctx, ACCEPT);
	assert_eq!(recorder.disposed.get(), 1);
	assert_eq!(state.open_exchanges(), 0);
	done(ctx, ACCEPT);
	assert_eq!(recorder.disposed.get(), 1, "a second done disposes nothing");
}

#[test]
fn an_offer_the_library_refuses_starts_no_exchange() {
	let (recorder, verbs, state) = state(Offer::Pending);
	verbs.code.set(sys::ERR_IO);
	let error = state.provide_offer("offerer", "offer-sdp").unwrap_err();
	assert_eq!(error.code(), sys::ERR_IO);
	assert_eq!(
		recorder.subscribed.get(),
		0,
		"no subscription for an exchange that never started"
	);
	assert_eq!(state.open_exchanges(), 0);
}

#[test]
fn a_given_up_accept_ends_with_done() {
	let (recorder, verbs, state) = state(Offer::Pending);
	let exchange = state.provide_offer("offerer", "offer-sdp").unwrap();
	state.fail_exchange(exchange).unwrap();
	assert_eq!(*verbs.calls.borrow(), [("offer", ACCEPT), ("fail", ACCEPT)]);
	done(state.ctx(), exchange);
	assert_eq!(recorder.disposed.get(), 1);
	assert_eq!(state.open_exchanges(), 0);
}

#[test]
fn a_give_up_the_library_refuses_changes_nothing() {
	let (recorder, verbs, state) = state(Offer::Pending);
	let exchange = state.provide_offer("offerer", "offer-sdp").unwrap();
	verbs.code.set(sys::ERR_INVALID_ARGUMENT);
	let error = state.fail_exchange(exchange).unwrap_err();
	assert_eq!(error.code(), sys::ERR_INVALID_ARGUMENT);
	assert_eq!(recorder.disposed.get(), 0);
	assert_eq!(state.open_exchanges(), 1);
}

#[test]
fn an_authority_may_hand_in_an_offer_from_inside_candidate() {
	let (recorder, _verbs, state) = state(Offer::Pending);
	let first = state.provide_offer("offerer", "offer-sdp").unwrap();
	*recorder.loopback.borrow_mut() = Some(Rc::downgrade(&state));
	assert_eq!(candidate(state.ctx(), first, "{\"candidate\":\"c\"}"), 0);
	assert_eq!(
		state.open_exchanges(),
		2,
		"the offer handed in from the callback started its own accept"
	);
}
