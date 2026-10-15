//! WebRTC for the async surface (the `webrtc` feature).
//!
//! The application supplies a [`SignalingAuthority`], the way the offer, the
//! answer, and each ICE candidate travel between peers. [`provider`] composes
//! the WebRTC C library into a [`crate::Runtime`], and an ordinary
//! [`crate::Runtime::connect`] to a [`locator`] then dials through the driver
//! loop. [`listen`] composes the same library into a Host that answers: the
//! application hands each inbound offer to [`Server::provide_offer`], and
//! [`Server::accept`] yields the session, whose partner identity names the
//! offerer. The C library runs each exchange and calls this module's
//! trampolines on the thread that steps the loop, so a `Runtime` or `Server`
//! must be driven from a tokio `LocalSet`.
//!
//! The raw C ABI stays public at its multiplexed readiness and try-I/O
//! boundary. Its functions are unsafe C calls and return glowcap result codes
//! exactly as declared in `glowcap_net_transport_webrtc.h`. The Rust browser
//! adapter lives in `browser::RtcPeer` and calls the browser's WebRTC
//! implementation.

use std::future::Future;
use std::pin::Pin;
use std::rc::Rc;

use crate::{HintWireForm, Host, ListenerIdentity, Locator, Result, Session};

pub use crate::sys::GlowcapTransportProvider;
pub use crate::sys::webrtc::*;

mod netlayer;
pub use netlayer::Netlayer;

#[cfg(test)]
mod tests;

/// One ICE server the C library gathers candidates through. An empty
/// `username` and `credential` mean the server needs none.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct IceServer {
	pub urls: Vec<String>,
	pub username: String,
	pub credential: String,
}

/// One WebRTC netlayer's settings. The default has no ICE servers, so only
/// host candidates are gathered, and leaves loopback addresses out.
/// `include_loopback_candidates` adds them, for two peers on one machine.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct Config {
	pub ice_servers: Vec<IceServer>,
	pub include_loopback_candidates: bool,
}

/// The peer one exchange is with, borrowed for a signaling call.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Target<'a> {
	/// The hex key designator of the dialed locator, or of the offerer whose
	/// offer [`Server::provide_offer`] took.
	pub designator: &'a str,
	/// The designator of the session that handed over the reference this dial
	/// follows, so the authority can carry signaling through the party that
	/// knows the peer. `None` for a dial the application started itself or
	/// whose introducing session signed no designator, and for every accept.
	pub introducer: Option<&'a str>,
}

/// A refusal from a signaling callback: the application could not carry the
/// offer or candidate, and `message` says why. The provider keeps it in
/// [`crate::take_runtime_failures`] and the dial fails.
pub fn refusal(message: impl Into<String>) -> crate::Error {
	crate::Error::with_detail(crate::sys::ERR_IO, message.into())
}

/// How offers, answers, and candidates reach the far peer.
///
/// The C library calls these on the thread that steps the driver loop, so none
/// of them may block. `offer` runs as a local task on that thread. Every call
/// names its exchange by the id the library minted, and the calls that open an
/// exchange's route name its [`Target`] too. For one dial, `on_candidate` is
/// called first, then `offer`, then `candidate` for each local candidate. For
/// one accept, `answer` runs inside [`Server::provide_offer`], then
/// `on_candidate`, then `candidate` for each local candidate. An authority that
/// only dials never has `answer` called, and one that only answers never has
/// `offer` called.
///
/// The far peer may trickle candidates before `on_candidate` subscribes, so
/// the authority holds what arrives for an exchange until its sink exists.
/// Two exchanges with one peer, such as a dial crossing that peer's own dial,
/// run side by side, and CapTP keeps one of their sessions.
pub trait SignalingAuthority {
	/// Carry the SDP offer for the dial `exchange` to `target` and resolve with
	/// its SDP answer.
	fn offer(&self, exchange: u64, target: Target<'_>, sdp: &str) -> Pin<Box<dyn Future<Output = Result<String>>>>;

	/// Carry the SDP answer for the accept `exchange` to `target`, the offerer
	/// whose offer [`Server::provide_offer`] took. An error refuses that offer.
	fn answer(&self, exchange: u64, target: Target<'_>, sdp: &str) -> Result<()>;

	/// Carry one local ICE candidate for `exchange`, as the JSON text of an
	/// `RTCIceCandidateInit`.
	fn candidate(&self, exchange: u64, ice: &str) -> Result<()>;

	/// Subscribe to the far peer's candidates for `exchange`, which is with
	/// `target`. Call `sink` with each candidate's JSON text. The returned
	/// function ends the subscription.
	fn on_candidate(&self, exchange: u64, target: Target<'_>, sink: Box<dyn Fn(String)>) -> Box<dyn FnOnce()>;
}

/// Build a WebRTC locator for the peer whose key designator is `designator`.
/// A WebRTC locator carries no hints.
pub fn locator(designator: &str) -> Locator {
	Locator {
		transport: crate::TRANSPORT_WEBRTC.to_string(),
		designator: designator.to_string(),
		hints: std::collections::BTreeMap::new(),
		hint_wire_form: HintWireForm::BooleanFalse,
	}
}

/// Configure a WebRTC netlayer package for a generic [`crate::Runtime::connect`]
/// operation. Needs the WebRTC C library (`zig build webrtc-abi`). A Host that
/// should also answer offers uses [`listen`] instead.
///
/// Each dial runs one signaling exchange through `signaling`. A dial whose
/// answer never arrives fails at the driver's handshake deadline. When `offer`
/// or `candidate` returns an error, the provider keeps it in
/// [`crate::take_runtime_failures`] and the dial fails at the driver's next
/// step instead. An answer the library refuses is kept the same way.
pub fn provider(signaling: Rc<dyn SignalingAuthority>, config: Config) -> crate::driver_loop::Provider {
	crate::driver_loop::Provider::new(move |lp| {
		let signaling = Rc::clone(&signaling);
		let config = config.clone();
		async move {
			install(&lp, signaling, &config)?;
			Ok(())
		}
	})
}

/// Put one netlayer on `lp` and return the state its callbacks read.
fn install(
	lp: &Rc<crate::driver_loop::LoopShared>,
	signaling: Rc<dyn SignalingAuthority>,
	config: &Config,
) -> Result<Rc<netlayer::State>> {
	let netlayer = Netlayer::new(signaling, config)?;
	lp.add_provider(netlayer.transport_provider()?)?;
	let state = netlayer.state();
	// The driver's provider lease keeps the C library running, and the
	// netlayer's callback state and handle must outlast that lease. The loop
	// keeps them until its driver has been released.
	lp.retain_until_teardown(Box::new(netlayer));
	Ok(state)
}

/// Listener construction options. See [`ListenerIdentity`] for the difference
/// between restoring an identity and sharing an existing Host.
#[derive(Clone, Default)]
pub struct ListenOptions {
	pub identity: ListenerIdentity,
}

/// A Host answering WebRTC offers: the WebRTC sibling of [`crate::tcp::Server`].
/// The driver loop owns the netlayer, the listener, the accept handshake, and
/// every accepted session. This type is the public view over that lifecycle
/// plus the one verb WebRTC adds, [`Server::provide_offer`].
pub struct Server {
	listener: crate::server::LoopListener,
	state: Rc<netlayer::State>,
	designator: String,
}

/// Compose a WebRTC netlayer into the Host `options.identity` names and open
/// its listener. Needs the WebRTC C library (`zig build webrtc-abi`).
///
/// A WebRTC peer is reachable only as its key, so the listener's designator
/// is the Host's own. The same netlayer dials: a [`crate::Runtime`] that
/// adopts [`Server::host`] with no further provider connects to a [`locator`]
/// through it. Each inbound offer reaches the library through
/// [`Server::provide_offer`], the offerer's candidates through the sink the
/// authority's `on_candidate` was given for that exchange, and
/// [`Server::accept`] yields
/// the session once the channel opens.
pub async fn listen(signaling: Rc<dyn SignalingAuthority>, config: Config, options: ListenOptions) -> Result<Server> {
	let (listener, (state, designator)) = crate::server::bind_loop_listener(
		options.identity,
		crate::abi_constants::TRANSPORT_WEBRTC,
		// An empty designator asks the library for the Host's own key.
		|_host, lp| async move { Ok((String::new(), install(&lp, signaling, &config)?)) },
		|lp, listener, _, state| Ok((state, lp.listener_locator(listener)?.designator)),
	)
	.await?;
	Ok(Server {
		listener,
		state,
		designator,
	})
}

impl Server {
	/// The Host shared by every accepted session. A [`crate::Runtime`] that
	/// adopts it dials through this server's netlayer.
	pub fn host(&self) -> Host {
		self.listener.host()
	}

	/// The hex key designator peers dial, the Host's own.
	pub fn designator(&self) -> &str {
		&self.designator
	}

	/// The locator partners dial this listener with.
	pub fn locator(&self) -> Result<Locator> {
		self.listener.locator()
	}

	/// Hand in an SDP offer from the peer whose designator is `designator`.
	/// The library answers it through the authority's `answer` before this
	/// returns, and the returned exchange id names the accept for
	/// [`Server::fail_exchange`]. An error means no exchange was started: the
	/// listener is closed, the offerer's key is not a key, too many accepts
	/// are in flight, or the authority refused the answer.
	///
	/// An accept has no deadline of its own. One whose offerer goes quiet holds
	/// its place until the application calls [`Server::fail_exchange`].
	pub fn provide_offer(&self, designator: &str, sdp: &str) -> Result<u64> {
		self.state.provide_offer(designator, sdp)
	}

	/// Give up on the accept `exchange` because its signaling broke or its
	/// offerer went quiet. It ends without a session and its candidate
	/// subscription is disposed. An error means no such accept is in progress
	/// or its channel has already opened, and nothing changed.
	pub fn fail_exchange(&self, exchange: u64) -> Result<()> {
		self.state.fail_exchange(exchange)
	}

	/// Await the next accepted session. Its partner identity names the
	/// offerer, authenticated by the signaling exchange that admitted it. It
	/// delivers its partner's inbound only once served: publish what it should
	/// answer, then `session.serve()`.
	pub async fn accept(&self) -> Result<Session> {
		self.listener.accept().await
	}

	/// Stop admission through this listener. Sessions already returned by
	/// [`Server::accept`] remain live on the shared Host, and [`Host::close`]
	/// is the terminal barrier.
	pub async fn close(&self) -> Result<()> {
		self.listener.close().await
	}

	/// Select this listener's locator as the shared Host's advertised
	/// location. See [`crate::tcp::Server::select`].
	pub fn select(&self) -> Result<()> {
		self.listener.select()
	}
}
