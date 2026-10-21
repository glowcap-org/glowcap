//! The netlayer handle and the signaling trampolines the C library calls.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::ffi::c_void;
use std::future::Future;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::pin::Pin;
use std::rc::{Rc, Weak};
use std::task::{Context, Poll};

use tokio::task::AbortHandle;

use super::{Config, SignalingAuthority, Target};
use crate::sys::webrtc as ffi;
use crate::{Error, FailureLayer, Result, sys};

crate::error_slot::error_slot!(
	fn check_webrtc;
	fn webrtc_last_error;
	ffi::glowcap_webrtc_last_error
);

/// What a callback returns to refuse the exchange.
const REFUSED: i32 = 1;

/// One exchange in flight: the subscription to the far peer's candidates,
/// and which side this netlayer is.
struct Exchange {
	dispose: Option<Box<dyn FnOnce()>>,
	role: Role,
}

/// Which side of an exchange this netlayer is.
enum Role {
	/// This netlayer offered. The task carries the offer and waits for the
	/// answer.
	Dial { answer: AbortHandle },
	/// The far peer offered, and the library answered inside
	/// [`State::provide_offer`].
	Accept,
}

impl Exchange {
	/// Stop waiting for the answer and end the candidate subscription.
	fn end(mut self) {
		if let Role::Dial { answer } = &self.role {
			answer.abort();
		}
		if let Some(dispose) = self.dispose.take() {
			dispose();
		}
	}
}

/// The state the C callbacks reach through `ctx`. It lives as long as the
/// [`Netlayer`] that owns the handle.
pub(super) struct State {
	signaling: Rc<dyn SignalingAuthority>,
	netlayer: Cell<*mut ffi::GlowcapWebrtcNetlayer>,
	exchanges: RefCell<HashMap<u64, Exchange>>,
	verbs: Rc<dyn Verbs>,
}

/// The four verbs the application hands the netlayer: the far peer's offer,
/// which starts an accept, and for a dial the far peer's answer, one of its
/// candidates, and giving the dial up. Each returns the library's code.
///
/// # Safety
/// `netlayer` must be a live handle for the whole call.
pub(super) trait Verbs {
	unsafe fn provide_offer(
		&self,
		netlayer: *mut ffi::GlowcapWebrtcNetlayer,
		designator: &str,
		sdp: &str,
		out_exchange: &mut u64,
	) -> i32;
	unsafe fn provide_answer(&self, netlayer: *mut ffi::GlowcapWebrtcNetlayer, exchange: u64, sdp: &str) -> i32;
	unsafe fn provide_candidate(&self, netlayer: *mut ffi::GlowcapWebrtcNetlayer, exchange: u64, ice: &str) -> i32;
	unsafe fn fail_exchange(&self, netlayer: *mut ffi::GlowcapWebrtcNetlayer, exchange: u64) -> i32;
}

/// The verbs of the WebRTC C library.
struct LibraryVerbs;

impl Verbs for LibraryVerbs {
	unsafe fn provide_offer(
		&self,
		netlayer: *mut ffi::GlowcapWebrtcNetlayer,
		designator: &str,
		sdp: &str,
		out_exchange: &mut u64,
	) -> i32 {
		// SAFETY: the caller keeps `netlayer` live for the call. `designator` and `sdp` are borrowed `str`s whose
		// pointers and lengths stay live for the call, the callee copies them, and `out_exchange` is a live `u64` the
		// callee writes.
		unsafe {
			ffi::glowcap_webrtc_netlayer_provide_offer(
				netlayer,
				designator.as_ptr(),
				designator.len(),
				sdp.as_ptr(),
				sdp.len(),
				out_exchange,
			)
		}
	}

	unsafe fn provide_answer(&self, netlayer: *mut ffi::GlowcapWebrtcNetlayer, exchange: u64, sdp: &str) -> i32 {
		// SAFETY: the caller keeps `netlayer` live for the call. `sdp` is a borrowed `str` whose pointer and length
		// stay live for the call, and the callee copies it.
		unsafe { ffi::glowcap_webrtc_netlayer_provide_answer(netlayer, exchange, sdp.as_ptr(), sdp.len()) }
	}

	unsafe fn provide_candidate(&self, netlayer: *mut ffi::GlowcapWebrtcNetlayer, exchange: u64, ice: &str) -> i32 {
		// SAFETY: as `provide_answer`, with `ice` borrowed for the call and copied by the callee.
		unsafe { ffi::glowcap_webrtc_netlayer_provide_candidate(netlayer, exchange, ice.as_ptr(), ice.len()) }
	}

	unsafe fn fail_exchange(&self, netlayer: *mut ffi::GlowcapWebrtcNetlayer, exchange: u64) -> i32 {
		// SAFETY: the caller keeps `netlayer` live for the call.
		unsafe { ffi::glowcap_webrtc_netlayer_fail_exchange(netlayer, exchange) }
	}
}

fn record(operation: &str, error: Error) {
	crate::record_runtime_failure(FailureLayer::Binding, operation, error);
}

/// Refuse a callback whose text from the C library is not UTF-8, or is a null
/// pointer with a length, and leave the refusal on record.
fn refuse_text(operation: &str) -> i32 {
	record(
		operation,
		Error::with_detail(
			sys::ERR_INVALID_ARGUMENT,
			"the C library handed the callback text that is not UTF-8, or a null pointer with a length".to_string(),
		),
	);
	REFUSED
}

/// Polls the application's offer inside `catch_unwind`, so a panic in it ends
/// the dial like an error instead of ending the task with nothing recorded.
struct CatchUnwind<F: Future + Unpin>(F);

impl<F: Future + Unpin> Future for CatchUnwind<F> {
	type Output = std::thread::Result<F::Output>;

	fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
		match catch_unwind(AssertUnwindSafe(|| Pin::new(&mut self.0).poll(cx))) {
			Ok(Poll::Pending) => Poll::Pending,
			Ok(Poll::Ready(value)) => Poll::Ready(Ok(value)),
			Err(payload) => Poll::Ready(Err(payload)),
		}
	}
}

fn panicked_offer() -> Error {
	Error::with_detail(sys::ERR_IO, "the signaling offer panicked".to_string())
}

impl State {
	fn send_offer(self: &Rc<Self>, exchange: u64, designator: String, introducer: Option<String>, sdp: String) -> i32 {
		if self.exchanges.borrow().contains_key(&exchange) {
			return REFUSED;
		}
		let candidates = Rc::downgrade(self);
		let sink: Box<dyn Fn(String)> = Box::new(move |ice| {
			if let Some(state) = Weak::upgrade(&candidates) {
				state.settle("webrtc-provide-candidate", state.provide_candidate(exchange, &ice));
			}
		});
		let target = Target {
			designator: &designator,
			introducer: introducer.as_deref(),
		};
		let dispose = self.signaling.on_candidate(exchange, target, sink);
		let state = Rc::clone(self);
		let task = crate::host::try_spawn_local_handle(async move {
			let target = Target {
				designator: &designator,
				introducer: introducer.as_deref(),
			};
			let answer = match catch_unwind(AssertUnwindSafe(|| state.signaling.offer(exchange, target, &sdp))) {
				Ok(future) => CatchUnwind(future).await,
				Err(payload) => Err(payload),
			};
			let answer = answer.unwrap_or_else(|_| Err(panicked_offer()));
			if !state.exchanges.borrow().contains_key(&exchange) {
				return;
			}
			match answer {
				Ok(answer) => state.settle("webrtc-provide-answer", state.provide_answer(exchange, &answer)),
				Err(error) => {
					record("webrtc-signaling-offer", error);
					state.settle("webrtc-fail-exchange", state.fail_exchange(exchange));
				}
			}
		});
		let Some(task) = task else {
			dispose();
			record(
				"webrtc-signaling-offer",
				Error::with_detail(
					sys::ERR_INVALID_ARGUMENT,
					"a WebRTC dial must be stepped from a tokio LocalSet".to_string(),
				),
			);
			return REFUSED;
		};
		self.exchanges.borrow_mut().insert(
			exchange,
			Exchange {
				dispose: Some(dispose),
				role: Role::Dial {
					answer: task.abort_handle(),
				},
			},
		);
		0
	}

	// The library produced the answer for an accept and hands it out through
	// the authority before `provide_offer` returns, so a refusal fails that
	// call. The exchange is not in the table yet: the table learns it from status-allow: pending state or quoted runtime label
	// `provide_offer`'s own return.
	fn send_answer(&self, exchange: u64, designator: &str, sdp: &str) -> i32 {
		let target = Target {
			designator,
			introducer: None,
		};
		match self.signaling.answer(exchange, target, sdp) {
			Ok(()) => 0,
			Err(error) => {
				record("webrtc-signaling-answer", error);
				REFUSED
			}
		}
	}

	/// Hand an inbound offer from `designator` to the library. The library
	/// builds the answerer, carries the answer out through the authority's
	/// `answer` during this call, and names the accept exchange it returns.
	/// The offerer's candidates are then subscribed under that exchange, and
	/// the driver's listener reports the connection once the channel opens.
	pub(super) fn provide_offer(self: &Rc<Self>, designator: &str, sdp: &str) -> Result<u64> {
		let mut exchange = 0u64;
		// SAFETY: `call` hands the handle over only while it is live.
		self.call(|raw| unsafe { self.verbs.provide_offer(raw, designator, sdp, &mut exchange) })?;
		let target = Target {
			designator,
			introducer: None,
		};
		let candidates = Rc::downgrade(self);
		let sink: Box<dyn Fn(String)> = Box::new(move |ice| {
			if let Some(state) = Weak::upgrade(&candidates) {
				state.settle("webrtc-provide-candidate", state.provide_candidate(exchange, &ice));
			}
		});
		let dispose = self.signaling.on_candidate(exchange, target, sink);
		self.exchanges.borrow_mut().insert(
			exchange,
			Exchange {
				dispose: Some(dispose),
				role: Role::Accept,
			},
		);
		Ok(exchange)
	}

	// A candidate the application cannot carry fails the exchange through the
	// callback's own return value. This runs inside the driver's step, where
	// the give-up verb is never called.
	fn send_candidate(&self, exchange: u64, ice: &str) -> i32 {
		// The authority may call back into this netlayer (a loopback authority
		// hands an offer to `provide_offer`), so no table borrow spans the call.
		if !self.exchanges.borrow().contains_key(&exchange) {
			return 0;
		}
		match self.signaling.candidate(exchange, ice) {
			Ok(()) => 0,
			Err(error) => {
				record("webrtc-signaling-candidate", error);
				REFUSED
			}
		}
	}

	fn done(&self, exchange: u64) {
		let entry = self.exchanges.borrow_mut().remove(&exchange);
		if let Some(entry) = entry {
			entry.end();
		}
	}

	fn provide_answer(&self, exchange: u64, sdp: &str) -> Result<()> {
		// SAFETY: `call` hands the handle over only while it is live.
		self.call(|raw| unsafe { self.verbs.provide_answer(raw, exchange, sdp) })
	}

	fn provide_candidate(&self, exchange: u64, ice: &str) -> Result<()> {
		// SAFETY: as `provide_answer`.
		self.call(|raw| unsafe { self.verbs.provide_candidate(raw, exchange, ice) })
	}

	/// Give up on `exchange` because its signaling failed. A dial fails at the
	/// driver's next step instead of at the handshake deadline, and an accept
	/// ends quietly with `done`, which disposes its subscription. An error
	/// means no such exchange is signaling, and nothing changed.
	pub(super) fn fail_exchange(&self, exchange: u64) -> Result<()> {
		// SAFETY: as `provide_answer`.
		self.call(|raw| unsafe { self.verbs.fail_exchange(raw, exchange) })
	}

	// Hand one verb to the netlayer while the handle is live. `close` ends that
	// by clearing the handle before `Netlayer` releases it.
	fn call(&self, verb: impl FnOnce(*mut ffi::GlowcapWebrtcNetlayer) -> i32) -> Result<()> {
		let raw = self.netlayer.get();
		if raw.is_null() {
			return Err(Error::from_code(sys::ERR_CLOSED));
		}
		match verb(raw) {
			sys::OK => Ok(()),
			code => Err(Error::with_transport_detail(code, webrtc_last_error())),
		}
	}

	// Record a verb's failure where no caller can take it. A late answer,
	// candidate, or give-up after the exchange ended, or after `close`, is
	// refused with no effect and needs no record.
	fn settle(&self, operation: &str, result: Result<()>) {
		if let Err(error) = result
			&& error.code() != sys::ERR_INVALID_ARGUMENT
			&& error.code() != sys::ERR_CLOSED
		{
			record(operation, error);
		}
	}

	// Stop every exchange. The handle is cleared first so a task that wakes
	// later provides nothing.
	fn close(&self) {
		self.netlayer.set(core::ptr::null_mut());
		let entries: Vec<Exchange> = self.exchanges.borrow_mut().drain().map(|(_, entry)| entry).collect();
		for entry in entries {
			entry.end();
		}
	}
}

/// Borrow `ctx` as the state the netlayer registered.
///
/// # Safety
/// `ctx` must be the pointer `Netlayer::new` registered, while its `Netlayer`
/// lives.
unsafe fn state_of(ctx: *mut c_void) -> Rc<State> {
	let state = ctx as *const State;
	// SAFETY: the caller's contract makes `state` the pointer `Rc::as_ptr` returned for a live `Rc<State>`, so the strong
	// count can be raised and a second `Rc` rebuilt from it.
	unsafe {
		Rc::increment_strong_count(state);
		Rc::from_raw(state)
	}
}

/// Borrow a text view the C library passed, or `None` for text that is not
/// UTF-8 or a null pointer with a length.
///
/// # Safety
/// `ptr` must be valid for `len` bytes for `'a`, which the caller bounds to
/// the callback.
unsafe fn borrow_text<'a>(ptr: *const u8, len: usize) -> Option<&'a str> {
	if len == 0 {
		return Some("");
	}
	if ptr.is_null() {
		return None;
	}
	// SAFETY: the caller's contract makes `ptr` valid for `len` bytes for `'a`.
	let bytes = unsafe { std::slice::from_raw_parts(ptr, len) };
	std::str::from_utf8(bytes).ok()
}

pub(super) unsafe extern "C" fn send_offer_trampoline(
	ctx: *mut c_void,
	exchange: u64,
	designator: *const u8,
	designator_len: usize,
	introducer: *const u8,
	introducer_len: usize,
	sdp: *const u8,
	sdp_len: usize,
) -> i32 {
	catch_unwind(AssertUnwindSafe(|| {
		// SAFETY: the C library passes back the `ctx` registered in `Netlayer::new`, and the three views are borrowed
		// for this call, which copies what the exchange keeps. A null introducer with a zero length is a dial no
		// session introduced.
		let (state, designator, introducer, sdp) = unsafe {
			(
				state_of(ctx),
				borrow_text(designator, designator_len),
				if introducer.is_null() && introducer_len == 0 {
					Some(None)
				} else {
					borrow_text(introducer, introducer_len).map(Some)
				},
				borrow_text(sdp, sdp_len),
			)
		};
		match (designator, introducer, sdp) {
			(Some(designator), Some(introducer), Some(sdp)) => state.send_offer(
				exchange,
				designator.to_owned(),
				introducer.map(str::to_owned),
				sdp.to_owned(),
			),
			_ => refuse_text("webrtc-signaling-offer"),
		}
	}))
	.unwrap_or(REFUSED)
}

pub(super) unsafe extern "C" fn send_answer_trampoline(
	ctx: *mut c_void,
	exchange: u64,
	designator: *const u8,
	designator_len: usize,
	sdp: *const u8,
	sdp_len: usize,
) -> i32 {
	catch_unwind(AssertUnwindSafe(|| {
		// SAFETY: as `send_offer_trampoline`.
		let (state, designator, sdp) = unsafe {
			(
				state_of(ctx),
				borrow_text(designator, designator_len),
				borrow_text(sdp, sdp_len),
			)
		};
		match (designator, sdp) {
			(Some(designator), Some(sdp)) => state.send_answer(exchange, designator, sdp),
			_ => refuse_text("webrtc-signaling-answer"),
		}
	}))
	.unwrap_or(REFUSED)
}

pub(super) unsafe extern "C" fn send_candidate_trampoline(
	ctx: *mut c_void,
	exchange: u64,
	ice: *const u8,
	ice_len: usize,
) -> i32 {
	catch_unwind(AssertUnwindSafe(|| {
		// SAFETY: as `send_offer_trampoline`.
		let (state, ice) = unsafe { (state_of(ctx), borrow_text(ice, ice_len)) };
		match ice {
			Some(ice) => state.send_candidate(exchange, ice),
			None => refuse_text("webrtc-signaling-candidate"),
		}
	}))
	.unwrap_or(REFUSED)
}

pub(super) unsafe extern "C" fn done_trampoline(ctx: *mut c_void, exchange: u64) {
	// A panic must not cross the C frame. The exchange then stays until close.
	let _ = catch_unwind(AssertUnwindSafe(|| {
		// SAFETY: as `send_offer_trampoline`.
		unsafe { state_of(ctx) }.done(exchange);
	}));
}

/// One WebRTC netlayer: the C handle and the signaling state its callbacks
/// read. Dropping it releases the handle, so it must outlive the driver loop
/// that holds its provider package. [`provider`](super::provider) and
/// [`listen`](super::listen) arrange that.
pub struct Netlayer {
	raw: *mut ffi::GlowcapWebrtcNetlayer,
	state: Rc<State>,
}

impl Netlayer {
	/// Create a netlayer that dials and answers through `signaling`.
	pub fn new(signaling: Rc<dyn SignalingAuthority>, config: &Config) -> Result<Netlayer> {
		crate::require_archive_fingerprint(
			"webrtc",
			// SAFETY: `glowcap_webrtc_archive_fingerprint` takes no arguments and returns a scalar.
			unsafe { ffi::glowcap_webrtc_archive_fingerprint() },
			crate::abi_constants::WEBRTC_ARCHIVE_FINGERPRINT,
		)?;
		let state = Rc::new(State {
			signaling,
			netlayer: Cell::new(core::ptr::null_mut()),
			exchanges: RefCell::new(HashMap::new()),
			verbs: Rc::new(LibraryVerbs),
		});
		// The views borrow `config`, which the callee copies during `netlayer_new`.
		let urls: Vec<Vec<ffi::GlowcapWebrtcStringView>> = config
			.ice_servers
			.iter()
			.map(|server| server.urls.iter().map(|url| view(url)).collect())
			.collect();
		let servers: Vec<ffi::GlowcapWebrtcIceServer> = config
			.ice_servers
			.iter()
			.zip(&urls)
			.map(|(server, urls)| ffi::GlowcapWebrtcIceServer {
				urls: urls.as_ptr(),
				url_count: urls.len(),
				username: view(&server.username),
				credential: view(&server.credential),
			})
			.collect();
		let raw_config = ffi::GlowcapWebrtcConfig {
			ice_servers: if servers.is_empty() {
				core::ptr::null()
			} else {
				servers.as_ptr()
			},
			ice_server_count: servers.len(),
			include_loopback_candidates: u32::from(config.include_loopback_candidates),
			worker_threads: 0,
			signaling: ffi::GlowcapWebrtcSignaling {
				ctx: Rc::as_ptr(&state) as *mut c_void,
				send_offer: Some(send_offer_trampoline),
				send_answer: Some(send_answer_trampoline),
				send_candidate: Some(send_candidate_trampoline),
				done: Some(done_trampoline),
			},
		};
		let mut raw: *mut ffi::GlowcapWebrtcNetlayer = core::ptr::null_mut();
		// SAFETY: `raw_config` is a local `GlowcapWebrtcConfig` whose server and URL views borrow `servers`, `urls`, and
		// `config`, all live for the call, and the callee copies them. `ctx` is the pointer of `state`, which the
		// returned `Netlayer` keeps alive. `raw` is a local out-parameter the callee fills with the new handle.
		check_webrtc(unsafe { ffi::glowcap_webrtc_netlayer_new(&raw_config, &mut raw) })?;
		state.netlayer.set(raw);
		Ok(Netlayer { raw, state })
	}

	/// The state the callbacks read, which outlives this handle's place on the
	/// loop: [`super::Server`] hands offers in through it.
	pub(super) fn state(&self) -> Rc<State> {
		Rc::clone(&self.state)
	}

	/// Return this netlayer's archive-owned provider package.
	pub fn transport_provider(&self) -> Result<crate::driver_loop::ProviderPackage<'_>> {
		// SAFETY: `GlowcapTransportProvider` is a plain C struct of integers and null pointers, so all-zero is a valid
		// value, and the callee fills it before it is read.
		let mut package: crate::sys::GlowcapTransportProvider = unsafe { core::mem::zeroed() };
		// SAFETY: `self.raw` is the live netlayer handle this `Netlayer` owns. `package` is a local out-parameter the
		// callee fills, and the returned `ProviderPackage` borrows `self` so the handle outlives it.
		check_webrtc(unsafe { ffi::glowcap_webrtc_transport_provider(self.raw, &mut package) })?;
		Ok(crate::driver_loop::ProviderPackage {
			package,
			_owner: core::marker::PhantomData,
		})
	}
}

fn view(text: &str) -> ffi::GlowcapWebrtcStringView {
	ffi::GlowcapWebrtcStringView {
		ptr: text.as_ptr(),
		len: text.len(),
	}
}

impl Drop for Netlayer {
	fn drop(&mut self) {
		self.state.close();
		// SAFETY: `self.raw` is the handle `glowcap_webrtc_netlayer_new` returned. `Drop` runs once, the state no longer status-allow: lifecycle transition
		// provides through it, and the driver loop that held its package has already released.
		if let Err(error) = check_webrtc(unsafe { ffi::glowcap_webrtc_netlayer_release(self.raw) }) {
			record("webrtc-netlayer-drop-release", error);
		}
	}
}

#[cfg(test)]
impl State {
	/// A state over fake verbs. Its handle is a stand-in the fakes receive and
	/// never dereference, so the verbs run as they would for a live netlayer.
	pub(super) fn for_test(signaling: Rc<dyn SignalingAuthority>, verbs: Rc<dyn Verbs>) -> Rc<State> {
		Rc::new(State {
			signaling,
			netlayer: Cell::new(core::ptr::NonNull::dangling().as_ptr()),
			exchanges: RefCell::new(HashMap::new()),
			verbs,
		})
	}

	pub(super) fn ctx(self: &Rc<Self>) -> *mut c_void {
		Rc::as_ptr(self) as *mut c_void
	}

	pub(super) fn open_exchanges(&self) -> usize {
		self.exchanges.borrow().len()
	}
}
