//! Idiomatic Rust API for pancake — an OCapN/CapTP [`Host`] whose partners
//! you hold as a [`Session`].
//!
//! The raw C ABI lives in the private `sys` module; nothing in it escapes.
//! What you use is the application surface every pancake binding speaks —
//! [`Runtime::connect`] plus transport-module `listen`, a [`Session`] with `fetch`/`send`/`tell`/
//! `spawn`/`publish`, one opaque [`Ref`] capability type, a Rust [`Argument`]
//! enum, and `Result` for fallible calls — over the symbol-disjoint
//! `libpancake_host` and `libpancake_driver` archives (ADR-0112). The Host
//! archive owns `pancake_host_*`; the driver exports only `pancake_driver_*`
//! and adopts a quiescent Host. Bounded `tcp`, `keyed-tcp`, `noise-tcp`, `iroh`, and routed relay dials and
//! listeners ride the loop ([`driver_loop`]); a quiescent caller-supplied Host
//! transfers to that same runtime before its first network operation. The
//! byte-fed pump serves explicit externally supplied channels such as a bare
//! relay locator's configured WebSocket fallback. The [`Host`] owns
//! `engine.Node` (router) and every CapTP decision; Goblins' `mycapn` is two
//! roles — product maps to Host, router tables map to `engine.Node` (ADR-0079). This
//! crate moves bytes and honors the host's action queue on the byte-fed
//! path. This is the dogfood consumer `zig build rust-dogfood` runs, so the
//! ergonomic surface stays honest.
//!
//! # Composable modules, à la carte
//!
//! pancake's C ABI ships as a set of symbol-disjoint archives (ADR-0059), and
//! this crate mirrors that shape: the core value/locator vocabulary and the
//! Host ABI is always available at the crate root, and each optional transport
//! is a module behind a Cargo feature that links exactly its archive — you pay
//! (in linked archive and symbols) only for the transports you enable. The
//! core stands alone; the transport modules build on it but never on each
//! other.
//!
//! | Feature | Module | Archive linked | Default |
//! | --- | --- | --- | --- |
//! | (always) | crate root + [`Locator`] | `libpancake_ocapn` + `libpancake_host` + `libpancake_driver` | yes |
//! | `tcp` | [`tcp`] | `libpancake_net_transport_tcp` | yes |
//! | `inproc` | [`inproc`] | `libpancake_net_transport_inproc` | yes |
//! | `onion` | [`onion`] | `libpancake_net_transport_onion` | no |
//! | `iroh` | [`iroh`] | `libpancake_net_transport_iroh` (dynamic) | no |
//! | `relay` | [`relay`] | `libpancake_net_transport_relay` | no |
//! | `async` | [`Session`], [`Host`], [`Runtime`] | (none — native tokio) | no |
//!
//! `tcp` and `inproc` are on by default. `onion` is opt-in because it needs a Tor
//! daemon the deployment runs; pancake starts none. `iroh` is opt-in and implies `async`
//! (the tokio driver it rides); it needs the companion library built by
//! `zig build iroh-abi`. The `async` feature adds the tokio-driven
//! [`Session`] over native sockets and links no transport archive of its
//! own, so it composes freely with whichever transport archives are enabled.

mod abi_constants;
// Reflected ABI constants (`zig build gen-binding-constants`); re-exported
// through `abi_constants`.
mod abi_constants_gen;

#[cfg(feature = "async")]
mod session;
#[cfg(feature = "async")]
mod session_shared;
#[cfg(feature = "async")]
pub use session::{PartnerIdentity, SendRedeemingResult, Session, HANDSHAKE_TIMEOUT};
#[cfg(feature = "async")]
pub use session_shared::Caretaker;
#[cfg(feature = "async")]
mod host;
#[cfg(feature = "async")]
mod lifecycle;
#[cfg(feature = "async")]
mod trace;
#[cfg(feature = "async")]
pub use host::{Host, HostOptions, ListenerIdentity, Resolver};
#[cfg(feature = "async")]
pub use lifecycle::PendingWork;
#[cfg(feature = "async")]
pub use trace::{annotate_session, enable_trace, PayloadSummary, SessionMeta, TraceEvent, TraceKind, TraceSink};
#[cfg(feature = "async")]
mod trampoline;
// Byte-fed embedder pump: feed / flush / serve-loop / feed-refusal (crate-private).
#[cfg(feature = "async")]
mod pump;
// Host action decode + execute: pop / run (crate-private).
#[cfg(feature = "async")]
mod action;
#[cfg(feature = "async")]
// RemotePromise + send-target plumbing.
mod promise;
#[cfg(feature = "async")]
pub use promise::{AsSendTarget, RemotePromise};
// Distributed GC (ADR-0063) CapabilityGuard + drain.
#[cfg(feature = "async")]
mod gc;
// Transport-neutral dial composition over explicit providers/connectors.
#[cfg(feature = "async")]
mod connector;
#[cfg(feature = "async")]
mod dial;
#[cfg(feature = "async")]
mod runtime;
// TCP-provider listener implementation, re-exported only by `tcp`.
#[cfg(all(feature = "async", any(feature = "tcp", feature = "iroh", feature = "onion")))]
mod server;
#[cfg(feature = "async")]
mod tcp_listen;
// Generated HostAction kinds + decode (`zig build gen-binding-host-action`).
#[cfg(feature = "async")]
mod host_action_gen;

// Runtime is the one managed dialer over a typed locator. ConnectOptions is the
// per-operation call boundary; providers, connectors, Host identity, and the
// handshake budget are installed once at Runtime construction.
#[cfg(feature = "async")]
pub use dial::ConnectOptions;
#[cfg(feature = "async")]
pub use runtime::{Runtime, RuntimeConfig};

// Every pancake archive keeps its own thread-local last-error slot (ADR-0059);
// this macro mints each family's checker/reader pair over its archive's extern
// reader — the ocapn core here at the root, the host in `host`, and each
// transport in its module. Unconditional: the core pair below is its first user.
mod error_slot;

// The blocking transports, each its own à-la-carte archive, linked only when
// its feature is on (ADR-0059). They share the core value layout but never
// each other; the core stands alone without any of them.
#[cfg(feature = "inproc")]
pub mod inproc;
#[cfg(feature = "onion")]
pub mod onion;
#[cfg(feature = "relay")]
pub mod relay;
#[cfg(feature = "tcp")]
pub mod tcp;

// The iroh transport (its own optional companion library, ADR-0055): the
// encrypted-QUIC byte-stream bridge the `Session` pump carries a session over.
#[cfg(feature = "async")]
mod driver_event;
#[cfg(feature = "async")]
mod driver_failure;
/// Native `DriverLoop` tier and the route used by `Runtime` transports.
#[cfg(feature = "async")]
pub mod driver_loop;
#[cfg(feature = "async")]
pub use connector::{Connector, TransportOperationOptions};
#[cfg(feature = "iroh")]
pub mod iroh;

// OCapN locator URIs, core libpancake_ocapn vocabulary, so a TCP-only consumer reaches
// the grammar without the iroh companion library. One grammar, no hand-rolled
// percent codec. Transport packages construct typed locators; this module owns
// their generic model and explicit URI conversion.
mod uri;
pub use uri::{
	designator_host_port, encode_peer_locator, format_locator_uri, format_peer_uri, format_sturdyref, parse_locator,
	parse_sturdyref, HintValue, HintWireForm, Locator, SturdyRef,
};

/// OCapN transport / hint vocabulary; mirrors `model.transport.*`.
pub use abi_constants::{
	HINT_DIRECT_ADDRESSES, TRANSPORT_INPROC, TRANSPORT_IROH, TRANSPORT_KEYED_RELAY, TRANSPORT_KEYED_TCP,
	TRANSPORT_NOISE_RELAY, TRANSPORT_NOISE_TCP, TRANSPORT_TCP, TRANSPORT_WEBRTC,
};

mod carrier_failure;
mod sys;
pub use carrier_failure::{CarrierFailure, CarrierPhase};
mod runtime_failure;
#[cfg(all(test, feature = "async"))]
pub(crate) use runtime_failure::RUNTIME_FAILURE_TEST_LOCK;
#[cfg(test)]
pub(crate) use runtime_failure::{RuntimeFailureJournal, FAILURE_PAYLOAD_CAP, RUNTIME_FAILURE_CAP};

/// An actor behavior: handle a `(verb, args)` call, returning a reply or an
/// error message (which becomes a broken answer carrying those words). This is
/// what [`Session::spawn`]/[`Session::publish`] host and what a
/// [`Host::publish_giftable`] factory mints.
pub type Behavior = Box<dyn FnMut(&str, &[Argument]) -> std::result::Result<Argument, String>>;

/// Which layer of the session refused a frame: the codec (parsing), the session
/// (authority and table validity), or a foreign failure surfaced through
/// dispatch.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AbortDomain {
	Codec,
	Session,
	Foreign,
}

impl AbortDomain {
	/// Map `PancakeLastAbort.domain` to the host label the waist defines.
	/// Read by the async connection's feed-refusal path alone.
	#[cfg(feature = "async")]
	pub(crate) fn from_abi(domain: u32) -> Result<Self> {
		match domain {
			abi_constants::ABORT_DOMAIN_CODEC => Ok(AbortDomain::Codec),
			abi_constants::ABORT_DOMAIN_SESSION => Ok(AbortDomain::Session),
			abi_constants::ABORT_DOMAIN_FOREIGN => Ok(AbortDomain::Foreign),
			other => Err(Error::with_detail(
				sys::ERR_INTERNAL,
				format!("pancake ABI returned unknown abort domain {other}"),
			)),
		}
	}
}

/// The typed cause of a connection's most recent local dispatch failure, the
/// safe projection of `pancake_host_session_last_abort`. The flat `PANCAKE_ERR_*`
/// code names the failure family; this names the member: which layer refused,
/// the projected `op:abort` kind when one applies, the originating diagnostic,
/// any failure publishing that terminal abort, and bounded cleanup/consequence
/// failures that followed the originating error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AbortInfo {
	/// Which layer refused the frame.
	pub domain: AbortDomain,
	/// The wire name of the projected `op:abort` kind, when one was projected.
	pub kind: Option<String>,
	/// The static diagnostic message.
	pub message: String,
	/// The originating error name.
	pub error_name: String,
	/// Failure encoding or queueing the projected abort, when one occurred.
	pub abort_delivery_error_name: Option<String>,
	/// First cleanup or consequence failure after the originating error.
	pub secondary_error_name: Option<String>,
	/// Number of secondary failures observed; the first name is retained.
	pub secondary_error_count: u32,
}

/// The failure family behind an [`Error`], the matchable form of its
/// [`code`](Error::code). Each variant names one `PANCAKE_ERR_*` family the C
/// ABI returns, so a caller distinguishes a partner break from a transport fault
/// or a malformed frame without comparing against raw negative integers.
///
/// It is `#[non_exhaustive]` because the ABI may name a new family later; match
/// with a `_` (or [`Other`](ErrorKind::Other)) arm. [`Other`](ErrorKind::Other)
/// also carries any code with no named family (for example an internally-handled
/// would-block that surfaced as an error).
#[non_exhaustive]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorKind {
	/// A required pointer argument was null (`PANCAKE_ERR_NULL_POINTER`).
	NullPointer,
	/// An argument was out of range or otherwise invalid (`PANCAKE_ERR_INVALID_ARGUMENT`).
	InvalidArgument,
	/// The session refused the frame on authority or table grounds (`PANCAKE_ERR_SESSION`).
	Session,
	/// The codec could not parse or render the frame (`PANCAKE_ERR_CODEC`).
	Codec,
	/// An internal invariant failed (`PANCAKE_ERR_INTERNAL`).
	Internal,
	/// The session or connection is closed (`PANCAKE_ERR_CLOSED`); on a blocking
	/// transport read this is a clean EOF.
	Closed,
	/// A transport I/O operation failed (`PANCAKE_ERR_IO`); the underlying
	/// `std::io::Error` message rides [`Error::message`].
	Io,
	/// The frame was malformed (`PANCAKE_ERR_MALFORMED`).
	Malformed,
	/// The frame declared or reached past the connection's frame cap
	/// (`PANCAKE_ERR_FRAME_TOO_LARGE`).
	FrameTooLarge,
	/// A value the passable tree cannot carry (`PANCAKE_ERR_UNSUPPORTED_VALUE`),
	/// e.g. a handoff, sturdy, or broken target where an immediate value is
	/// required.
	UnsupportedValue,
	/// The partner broke a `send`/`fetch` (`PANCAKE_ERR_BROKEN`); the break
	/// reason rides [`Error::message`].
	Broken,
	/// A named lookup found nothing (`PANCAKE_ERR_NOT_FOUND`).
	NotFound,
	/// A caller-provided output buffer was too small
	/// (`PANCAKE_ERR_BUFFER_TOO_SMALL`).
	BufferTooSmall,
	/// A caller-set deadline elapsed (`PANCAKE_ERR_TIMEOUT`): the handshake or a
	/// blocking answer-wait ran out its budget. Nothing failed on the wire, so a
	/// retry with a longer budget is a reasonable response.
	TimedOut,
	/// Any other code with no named family (unknown or retired). The raw
	/// [`code`](Error::code) is preserved.
	Other(i32),
}

/// A failed pancake call. It always carries the negative `PANCAKE_ERR_*` code;
/// match its family with [`kind`](Error::kind) rather than the raw integer. When
/// a `send` was broken by the partner it also carries the break reason, so the
/// reason a partner gave for refusing a call is not lost behind a code.
/// Cleanup failures retain their own typed `Error` values in observation order
/// without replacing the originating failure.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
	code: i32,
	detail: Option<String>,
	abort: Option<AbortInfo>,
	secondary: Vec<Error>,
	secondary_count: u32,
	carrier: Option<CarrierFailure>,
}

pub(crate) fn record_runtime_failure(layer: FailureLayer, operation: &str, error: Error) {
	runtime_failure::record(layer, operation, error);
}

/// Atomically claim failures that outlived any Context or Host owner.
pub fn take_runtime_failures() -> Vec<FailureEvent> {
	runtime_failure::claim()
}

/// Render a caught panic payload without assuming that foreign or application
/// code used one particular payload type.
pub(crate) fn panic_message(payload: &(dyn std::any::Any + Send)) -> String {
	if let Some(text) = payload.downcast_ref::<&str>() {
		(*text).to_string()
	} else if let Some(text) = payload.downcast_ref::<String>() {
		text.clone()
	} else {
		"callback panicked".to_string()
	}
}

#[cfg(feature = "async")]
pub(crate) fn retain_cleanup_failure(primary: Error, cleanup: Result<()>) -> Error {
	match cleanup {
		Ok(()) => primary,
		Err(cleanup) => primary.with_secondary(cleanup),
	}
}

impl Error {
	fn diagnostic_name(&self) -> &'static str {
		match self.kind() {
			ErrorKind::NullPointer => "NullPointer",
			ErrorKind::InvalidArgument => "InvalidArgument",
			ErrorKind::Session => "Session",
			ErrorKind::Codec => "Codec",
			ErrorKind::Internal => "Internal",
			ErrorKind::Closed => "Closed",
			ErrorKind::Io => "Io",
			ErrorKind::Malformed => "Malformed",
			ErrorKind::FrameTooLarge => "FrameTooLarge",
			ErrorKind::UnsupportedValue => "UnsupportedValue",
			ErrorKind::Broken => "Broken",
			ErrorKind::NotFound => "NotFound",
			ErrorKind::BufferTooSmall => "BufferTooSmall",
			ErrorKind::TimedOut => "TimedOut",
			ErrorKind::Other(_) => "Other",
		}
	}

	/// The negative `PANCAKE_ERR_*` code for this failure.
	pub fn code(&self) -> i32 {
		self.code
	}

	/// The matchable failure family behind [`code`](Error::code). Prefer this to
	/// comparing the raw integer: `err.kind() == ErrorKind::Broken` reads a
	/// partner break, `ErrorKind::FrameTooLarge` a refused oversize frame,
	/// `ErrorKind::Io` a transport fault.
	pub fn kind(&self) -> ErrorKind {
		match self.code {
			sys::ERR_NULL_POINTER => ErrorKind::NullPointer,
			sys::ERR_INVALID_ARGUMENT => ErrorKind::InvalidArgument,
			sys::ERR_SESSION => ErrorKind::Session,
			sys::ERR_CODEC => ErrorKind::Codec,
			sys::ERR_INTERNAL => ErrorKind::Internal,
			sys::ERR_CLOSED => ErrorKind::Closed,
			sys::ERR_IO => ErrorKind::Io,
			sys::ERR_MALFORMED => ErrorKind::Malformed,
			sys::ERR_FRAME_TOO_LARGE => ErrorKind::FrameTooLarge,
			sys::ERR_UNSUPPORTED_VALUE => ErrorKind::UnsupportedValue,
			sys::ERR_BROKEN => ErrorKind::Broken,
			sys::ERR_NOT_FOUND => ErrorKind::NotFound,
			sys::ERR_BUFFER_TOO_SMALL => ErrorKind::BufferTooSmall,
			sys::ERR_TIMEOUT => ErrorKind::TimedOut,
			other => ErrorKind::Other(other),
		}
	}

	/// The diagnostic message for this failure. For a broken `send` it is the
	/// partner's break reason; otherwise it is the calling thread's C ABI message
	/// captured at the moment the failure was raised, so a later fallible call on
	/// the same thread cannot overwrite it. `None` when neither was set. Borrowed
	/// from the error; clone it if you need it to outlive the `Error`.
	pub fn message(&self) -> Option<&str> {
		self.detail.as_deref()
	}

	/// The typed abort cause the connection recorded when this failure refused
	/// an inbound frame; `None` for other failures. The flat
	/// [`code`](Error::code) names the failure family; this names the member.
	pub fn abort(&self) -> Option<&AbortInfo> {
		self.abort.as_ref()
	}

	/// Cleanup and consequence failures retained without replacing this error.
	pub fn secondary_errors(&self) -> &[Error] {
		&self.secondary
	}

	/// Total consequences observed, including any beyond the bounded exact list.
	pub fn secondary_error_count(&self) -> u32 {
		self.secondary_count
	}

	/// Carrier phase and neutral secure-transport detail, when the selected
	/// transport could identify the failure below relay semantics.
	pub fn carrier_failure(&self) -> Option<CarrierFailure> {
		self.carrier
	}

	#[cfg(any(feature = "async", feature = "onion"))]
	pub(crate) fn with_secondary(mut self, error: Error) -> Self {
		self.secondary_count = self.secondary_count.saturating_add(1);
		if self.secondary.len() < 64 {
			self.secondary.push(error);
		}
		self
	}

	#[cfg(feature = "async")]
	pub(crate) fn with_carrier_failure(mut self, carrier: Option<CarrierFailure>) -> Self {
		self.carrier = carrier;
		self
	}

	fn from_code(code: i32) -> Error {
		// Snapshot the thread-local message now, while it still belongs to the
		// call that just failed, matching the Python/Deno/Racket bindings.
		Error {
			code,
			detail: last_error(),
			abort: None,
			secondary: Vec::new(),
			secondary_count: 0,
			carrier: None,
		}
	}

	/// A binding-side failure with an explicit message, for a refusal the C ABI
	/// never saw (e.g. an `ocapn://` URI naming a transport this build cannot dial).
	pub(crate) fn with_detail(code: i32, detail: String) -> Error {
		Error {
			code,
			detail: Some(detail),
			abort: None,
			secondary: Vec::new(),
			secondary_count: 0,
			carrier: None,
		}
	}

	/// A failure carrying the diagnostic its own archive's thread-local
	/// last-error slot recorded (`pancake_last_error`, `pancake_host_last_error`,
	/// `pancake_<t>_last_error`). Every `error_slot!`-minted checker builds its
	/// `Err` through this, so a diagnostic is never read from the wrong slot.
	pub(crate) fn with_transport_detail(code: i32, detail: Option<String>) -> Error {
		Error {
			code,
			detail,
			abort: None,
			secondary: Vec::new(),
			secondary_count: 0,
			carrier: None,
		}
	}

	/// A broken promise carrying the partner's reason: a `send`/`fetch` the
	/// remote side refused, distinct from a fault in this host or the transport.
	/// Carries `PANCAKE_ERR_BROKEN` so a caller can tell a refusal apart from a
	/// real failure by [`kind`](Error::kind) (`ErrorKind::Broken`), with the
	/// reason on `detail`.
	#[cfg(feature = "async")]
	fn broken(message: String) -> Error {
		Error {
			code: sys::ERR_BROKEN,
			detail: Some(message),
			abort: None,
			secondary: Vec::new(),
			secondary_count: 0,
			carrier: None,
		}
	}

	#[cfg(feature = "async")]
	fn with_abort(mut self, abort: Option<AbortInfo>) -> Error {
		self.abort = abort;
		self
	}
}

impl std::fmt::Display for Error {
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		match self.message() {
			Some(msg) => write!(f, "pancake error {}: {msg}", self.code),
			None => write!(f, "pancake error {}", self.code),
		}
	}
}
impl std::error::Error for Error {}

/// The crate's result type: every fallible call fails with a typed [`Error`].
pub type Result<T> = core::result::Result<T, Error>;

#[cfg(any(
	test,
	feature = "tcp",
	feature = "inproc",
	feature = "onion",
	feature = "iroh",
	feature = "relay"
))]
pub(crate) fn require_archive_fingerprint(archive: &str, actual: u64, expected: u64) -> Result<()> {
	if actual == expected {
		return Ok(());
	}
	Err(Error::with_detail(
		sys::ERR_INTERNAL,
		format!(
			"{archive}: callable surface does not match this binding (expected {expected:016x}, got {actual:016x}); rebuild the native libraries"
		),
	))
}

/// Decode the shared close lifecycle without allowing an unknown native value
/// to masquerade as a still-running owner and park a binding task forever.
#[cfg(feature = "async")]
pub(crate) fn lifecycle_is_closed(raw: u32) -> Result<bool> {
	match raw {
		sys::LIFECYCLE_ACTIVE | sys::LIFECYCLE_FINISHING | sys::LIFECYCLE_TERMINATING => Ok(false),
		sys::LIFECYCLE_CLOSED => Ok(true),
		other => Err(Error::with_detail(
			sys::ERR_INTERNAL,
			format!("pancake ABI returned unknown lifecycle state {other}"),
		)),
	}
}

/// The layer that observed an unreturnable failure.
#[non_exhaustive]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FailureLayer {
	Core,
	Driver,
	Transport,
	Binding,
	ApplicationObserver,
}

impl FailureLayer {
	fn from_abi(value: u32) -> Result<Self> {
		match value {
			abi_constants_gen::FAILURE_LAYER_CORE => Ok(Self::Core),
			abi_constants_gen::FAILURE_LAYER_DRIVER => Ok(Self::Driver),
			abi_constants_gen::FAILURE_LAYER_TRANSPORT => Ok(Self::Transport),
			abi_constants_gen::FAILURE_LAYER_BINDING => Ok(Self::Binding),
			abi_constants_gen::FAILURE_LAYER_APPLICATION_OBSERVER => Ok(Self::ApplicationObserver),
			other => Err(Error::with_detail(
				sys::ERR_INTERNAL,
				format!("pancake ABI returned unknown failure layer {other}"),
			)),
		}
	}
}

/// The lifecycle owner whose operation produced an unreturnable failure.
#[non_exhaustive]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FailureScope {
	Process,
	Context,
	Host,
	Session,
	Listener,
	Transport,
	Operation,
}

impl FailureScope {
	fn from_abi(value: u32) -> Result<Self> {
		match value {
			abi_constants_gen::FAILURE_SCOPE_PROCESS => Ok(Self::Process),
			abi_constants_gen::FAILURE_SCOPE_CONTEXT => Ok(Self::Context),
			abi_constants_gen::FAILURE_SCOPE_HOST => Ok(Self::Host),
			abi_constants_gen::FAILURE_SCOPE_SESSION => Ok(Self::Session),
			abi_constants_gen::FAILURE_SCOPE_LISTENER => Ok(Self::Listener),
			abi_constants_gen::FAILURE_SCOPE_TRANSPORT => Ok(Self::Transport),
			abi_constants_gen::FAILURE_SCOPE_OPERATION => Ok(Self::Operation),
			other => Err(Error::with_detail(
				sys::ERR_INTERNAL,
				format!("pancake ABI returned unknown failure scope {other}"),
			)),
		}
	}
}

/// One failure that had no remaining deterministic return recipient.
///
/// Context diagnostics are an ordered, bounded audit trail. They do not
/// duplicate failures returned by an API, raised by a callback owner, or held
/// by a close barrier. `dropped_before` reports records evicted before this
/// claim; `secondary_count` preserves the number of consequences while the
/// first consequence remains typed in `secondary_*`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FailureEvent {
	pub sequence: u64,
	pub dropped_before: u64,
	pub layer: FailureLayer,
	pub scope: FailureScope,
	pub scope_id: u64,
	pub operation_id: u64,
	pub primary_result: i32,
	pub secondary_result: i32,
	pub secondary_count: u32,
	pub truncated_fields: u32,
	pub operation: String,
	pub primary_name: String,
	pub primary_message: String,
	pub secondary_name: String,
	pub secondary_message: String,
}

error_slot::error_slot!(
	// Maps a non-OK ocapn-family return code to an `Error` carrying the
	// message the slot recorded at the moment the call failed.
	fn check;
	/// The calling thread's last recorded ocapn-family error message, or `None` if
	/// none is set. The host family and each transport keep their own slots, read
	/// by their own family errors internally.
	pub fn last_error;
	sys::pancake_last_error
);

/// The linked `libpancake_ocapn`'s ABI version as `(major, minor, patch)`. Compare it
/// against the header constants the binding was built against to detect skew.
pub fn abi_version() -> (u32, u32, u32) {
	let (mut major, mut minor, mut patch) = (0u32, 0u32, 0u32);
	unsafe { sys::pancake_abi_version(&mut major, &mut minor, &mut patch) };
	(major, minor, patch)
}

/// A host-supplied allocation backend for a [`Context`]. Every method must be
/// thread-safe; the library may call them from any thread that touches a handle
/// created in the context.
pub trait ContextAllocator: Send + Sync {
	/// Return a block of at least `size` bytes aligned to `alignment`, or null on
	/// failure.
	fn alloc(&self, size: usize, alignment: usize) -> *mut u8;
	/// Release a block previously returned by [`alloc`](ContextAllocator::alloc).
	///
	/// # Safety
	/// `ptr` must have come from this allocator with the same `size`/`alignment`.
	unsafe fn free(&self, ptr: *mut u8, size: usize, alignment: usize);
}

// A panic must never cross an extern "C" frame (that is undefined behavior),
// and a `ContextAllocator` is user code: a panicking alloc degrades to the null
// the C side already handles as out-of-memory, and a panicking free is
// swallowed (the block leaks, the process survives).
unsafe extern "C" fn alloc_trampoline(
	user_data: *mut core::ffi::c_void,
	size: usize,
	alignment: usize,
) -> *mut core::ffi::c_void {
	match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
		let allocator = &*(user_data as *const Box<dyn ContextAllocator>);
		allocator.alloc(size, alignment) as *mut core::ffi::c_void
	})) {
		Ok(ptr) => ptr,
		Err(payload) => {
			record_runtime_failure(
				FailureLayer::Binding,
				"context-allocator-alloc-panic",
				Error::with_detail(sys::ERR_INTERNAL, panic_message(payload.as_ref())),
			);
			core::ptr::null_mut()
		}
	}
}

unsafe extern "C" fn free_trampoline(
	user_data: *mut core::ffi::c_void,
	ptr: *mut core::ffi::c_void,
	size: usize,
	alignment: usize,
) {
	if let Err(payload) = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
		let allocator = &*(user_data as *const Box<dyn ContextAllocator>);
		allocator.free(ptr as *mut u8, size, alignment);
	})) {
		record_runtime_failure(
			FailureLayer::Binding,
			"context-allocator-free-panic",
			Error::with_detail(sys::ERR_INTERNAL, panic_message(payload.as_ref())),
		);
	}
}

/// Shared native allocation policy retained by every high-level handle family
/// that cannot express the borrow in its public type.
pub(crate) struct ContextInner {
	pub(crate) raw: *mut sys::PancakeContext,
	// Kept alive (and freed after `pancake_context_release`) for the custom
	// allocator path; null for the default-allocator context.
	allocator: *mut Box<dyn ContextAllocator>,
}

/// An allocation scope. Hosts and netlayers created in a context route every
/// allocation through it. Borrowing netlayers carry the Context lifetime in
/// their type; shared Host state retains the native policy directly.
pub struct Context {
	// The no-feature build still exposes Context construction as a standalone
	// RAII policy proof, even though no optional handle family can borrow it.
	#[allow(dead_code)]
	inner: std::rc::Rc<ContextInner>,
}

impl Context {
	/// A context backed by the library-owned allocator.
	pub fn new() -> Result<Context> {
		Ok(Context {
			inner: std::rc::Rc::new(ContextInner::new()?),
		})
	}

	/// A context that routes every allocation through `allocator`.
	pub fn with_allocator(allocator: Box<dyn ContextAllocator>) -> Result<Context> {
		let user_data = Box::into_raw(Box::new(allocator));
		let c_allocator = sys::PancakeAllocator {
			alloc: alloc_trampoline,
			free: free_trampoline,
			user_data: user_data as *mut core::ffi::c_void,
		};
		let mut raw: *mut sys::PancakeContext = core::ptr::null_mut();
		let rc = unsafe { sys::pancake_context_new_with_allocator(&c_allocator, &mut raw) };
		if rc != sys::OK {
			unsafe { drop(Box::from_raw(user_data)) };
			return Err(Error::from_code(rc));
		}
		Ok(Context {
			inner: std::rc::Rc::new(ContextInner {
				raw,
				allocator: user_data,
			}),
		})
	}

	/// Atomically claim the oldest unreturnable failure retained by this
	/// context. A claimed event cannot reappear; events recorded concurrently
	/// remain ordered for later claims.
	pub fn next_failure(&self) -> Result<Option<FailureEvent>> {
		self.inner.next_failure()
	}

	/// Atomically claim every unreturnable failure currently retained by this
	/// context, in observation order.
	pub fn take_failures(&self) -> Result<Vec<FailureEvent>> {
		let mut failures = Vec::new();
		while let Some(failure) = self.next_failure()? {
			failures.push(failure);
		}
		Ok(failures)
	}

	#[cfg(any(feature = "tcp", feature = "inproc", feature = "onion"))]
	pub(crate) fn raw(&self) -> *mut sys::PancakeContext {
		self.inner.raw
	}

	#[cfg(feature = "async")]
	pub(crate) fn retain_inner(&self) -> std::rc::Rc<ContextInner> {
		std::rc::Rc::clone(&self.inner)
	}
}

impl ContextInner {
	pub(crate) fn new() -> Result<Self> {
		let mut raw: *mut sys::PancakeContext = core::ptr::null_mut();
		check(unsafe { sys::pancake_context_new(&mut raw) })?;
		Ok(Self {
			raw,
			allocator: core::ptr::null_mut(),
		})
	}

	#[cfg(feature = "async")]
	pub(crate) fn report_failure(
		&self,
		layer: FailureLayer,
		scope: FailureScope,
		scope_id: u64,
		operation_id: u64,
		operation: &str,
		error: &Error,
	) {
		let runtime_layer = layer;
		let layer = match layer {
			FailureLayer::Core => abi_constants_gen::FAILURE_LAYER_CORE,
			FailureLayer::Driver => abi_constants_gen::FAILURE_LAYER_DRIVER,
			FailureLayer::Transport => abi_constants_gen::FAILURE_LAYER_TRANSPORT,
			FailureLayer::Binding => abi_constants_gen::FAILURE_LAYER_BINDING,
			FailureLayer::ApplicationObserver => abi_constants_gen::FAILURE_LAYER_APPLICATION_OBSERVER,
		};
		let scope = match scope {
			FailureScope::Process => abi_constants_gen::FAILURE_SCOPE_PROCESS,
			FailureScope::Context => abi_constants_gen::FAILURE_SCOPE_CONTEXT,
			FailureScope::Host => abi_constants_gen::FAILURE_SCOPE_HOST,
			FailureScope::Session => abi_constants_gen::FAILURE_SCOPE_SESSION,
			FailureScope::Listener => abi_constants_gen::FAILURE_SCOPE_LISTENER,
			FailureScope::Transport => abi_constants_gen::FAILURE_SCOPE_TRANSPORT,
			FailureScope::Operation => abi_constants_gen::FAILURE_SCOPE_OPERATION,
		};
		let secondary = error.secondary.first();
		let report = sys::PancakeFailureReport {
			abi_version: 1,
			struct_size: core::mem::size_of::<sys::PancakeFailureReport>(),
			layer,
			scope_kind: scope,
			scope_id,
			operation_id,
			primary_result: error.code,
			secondary_result: secondary.map_or(0, |failure| failure.code),
			secondary_count: error.secondary_count,
			operation: operation.as_ptr(),
			operation_len: operation.len(),
			primary_name: error.diagnostic_name().as_ptr(),
			primary_name_len: error.diagnostic_name().len(),
			primary_message: error.detail.as_deref().map_or(core::ptr::null(), str::as_ptr),
			primary_message_len: error.detail.as_deref().map_or(0, str::len),
			secondary_name: secondary.map_or(core::ptr::null(), |failure| failure.diagnostic_name().as_ptr()),
			secondary_name_len: secondary.map_or(0, |failure| failure.diagnostic_name().len()),
			secondary_message: secondary
				.and_then(|failure| failure.detail.as_deref())
				.map_or(core::ptr::null(), str::as_ptr),
			secondary_message_len: secondary
				.and_then(|failure| failure.detail.as_deref())
				.map_or(0, str::len),
		};
		// Recording is observational. If the preferred Context refuses its own
		// diagnostic input, retain both facts in the bounded surviving queue
		// without replacing the protocol or teardown outcome.
		let rc = unsafe { sys::pancake_context_report_failure(self.raw, &report) };
		if rc != sys::OK {
			record_runtime_failure(runtime_layer, operation, error.clone());
			record_runtime_failure(FailureLayer::Binding, "diagnostic.record", Error::from_code(rc));
		}
	}

	pub(crate) fn next_failure(&self) -> Result<Option<FailureEvent>> {
		let mut event: sys::PancakeFailureEvent = unsafe { core::mem::zeroed() };
		let mut required = 0usize;
		let first =
			unsafe { sys::pancake_context_next_failure(self.raw, &mut event, core::ptr::null_mut(), 0, &mut required) };
		if first == sys::WOULD_BLOCK {
			return Ok(None);
		}
		if first != sys::ERR_BUFFER_TOO_SMALL && first != sys::OK {
			return Err(Error::from_code(first));
		}
		let mut payload = vec![0u8; required];
		if first == sys::ERR_BUFFER_TOO_SMALL {
			let rc = unsafe {
				sys::pancake_context_next_failure(
					self.raw,
					&mut event,
					payload.as_mut_ptr(),
					payload.len(),
					&mut required,
				)
			};
			check(rc)?;
		}

		unsafe fn text(ptr: *const u8, len: usize, field: &str) -> Result<String> {
			if len == 0 {
				return Ok(String::new());
			}
			if ptr.is_null() {
				return Err(Error::with_detail(
					sys::ERR_INTERNAL,
					format!("pancake ABI returned a null {field} with nonzero length"),
				));
			}
			let bytes = unsafe { core::slice::from_raw_parts(ptr, len) };
			let value = core::str::from_utf8(bytes).map_err(|_| {
				Error::with_detail(
					sys::ERR_INTERNAL,
					format!("pancake ABI returned invalid UTF-8 in {field}"),
				)
			})?;
			Ok(value.to_owned())
		}

		Ok(Some(FailureEvent {
			sequence: event.sequence,
			dropped_before: event.dropped_before,
			layer: FailureLayer::from_abi(event.layer)?,
			scope: FailureScope::from_abi(event.scope_kind)?,
			scope_id: event.scope_id,
			operation_id: event.operation_id,
			primary_result: event.primary_result,
			secondary_result: event.secondary_result,
			secondary_count: event.secondary_count,
			truncated_fields: event.flags,
			operation: unsafe { text(event.operation, event.operation_len, "failure operation")? },
			primary_name: unsafe { text(event.primary_name, event.primary_name_len, "primary failure name")? },
			primary_message: unsafe {
				text(
					event.primary_message,
					event.primary_message_len,
					"primary failure message",
				)?
			},
			secondary_name: unsafe { text(event.secondary_name, event.secondary_name_len, "secondary failure name")? },
			secondary_message: unsafe {
				text(
					event.secondary_message,
					event.secondary_message_len,
					"secondary failure message",
				)?
			},
		}))
	}
}

impl Drop for ContextInner {
	fn drop(&mut self) {
		// Release the context first — it frees its tables through the allocator —
		// then drop the host allocator the trampolines borrowed.
		unsafe { sys::pancake_context_release(self.raw) };
		if !self.allocator.is_null() {
			unsafe { drop(Box::from_raw(self.allocator)) };
		}
	}
}

/// An opaque capability identity in one Host. It is never a wire position and
/// its shape does not reveal whether the target is local, remote, or routed
/// through a handoff. `PartialEq` compares that immutable identity only;
/// occurrence-local release state does not change Target equality. The raw id
/// and C layout stay private to the binding.
#[derive(Debug, Clone)]
pub struct Ref {
	id: u64,
	#[cfg(feature = "async")]
	#[allow(dead_code)]
	guard: Option<std::rc::Rc<crate::gc::CapabilityGuard>>,
	released: std::rc::Rc<std::cell::Cell<bool>>,
}

impl PartialEq for Ref {
	fn eq(&self, other: &Self) -> bool {
		self.id == other.id
	}
}

impl Eq for Ref {}

impl Ref {
	pub fn released(&self) -> bool {
		self.released.get()
	}

	#[cfg(feature = "async")]
	pub(crate) fn mark_released(&self) {
		self.released.set(true);
	}

	#[cfg(feature = "async")]
	pub(crate) fn id(&self) -> u64 {
		self.id
	}

	#[cfg(feature = "async")]
	pub(crate) fn guard(&self) -> Option<&crate::gc::CapabilityGuard> {
		self.guard.as_deref()
	}

	#[cfg(feature = "async")]
	pub(crate) fn attach_guard(&mut self, guard: std::rc::Rc<crate::gc::CapabilityGuard>) {
		debug_assert!(self.guard.is_none());
		self.guard = Some(guard);
	}

	#[cfg(feature = "async")]
	pub(crate) fn bare_id(id: u64) -> Ref {
		Ref {
			id,
			#[cfg(feature = "async")]
			guard: None,
			released: std::rc::Rc::new(std::cell::Cell::new(false)),
		}
	}
}

// The C marshaling layer: used only by the async host tier, so it compiles
// only with it — dead-code linting stays live instead of blanket-allowed.
#[cfg(feature = "async")]
impl Ref {
	pub(crate) fn to_sys(&self) -> Result<sys::PancakeReference> {
		Ok(sys::PancakeReference { id: self.id })
	}

	pub(crate) fn from_sys(r: &sys::PancakeReference) -> Ref {
		Ref::bare_id(r.id)
	}
}

/// A passable argument value.
#[derive(Debug, Clone, PartialEq)]
pub enum Argument {
	Integer(i64),
	Float(f64),
	Boolean(bool),
	Bytes(Vec<u8>),
	String(String),
	Symbol(String),
	/// A fulfilled OCapN Error value. This is data, not a Rust `Err`; a broken
	/// remote reply is reported separately by the promise/session API.
	Error(String),
	Void,
	Reference(Ref),
	List(Vec<Argument>),
	Set(Vec<Argument>),
	Tagged {
		tag: String,
		value: Vec<Argument>,
	},
	Keyword(String),
	/// An arbitrary-precision OCapN Integer outside `i64` (ADR-0049): the sign
	/// plus the canonical decimal magnitude (ASCII digits, no leading zero).
	/// Parse `digits` into your own bignum type; pancake transports and
	/// compares the value, it does not compute with it.
	BigInteger {
		negative: bool,
		digits: String,
	},
	/// An OCapN Struct: unordered, uniquely named String fields. The vector
	/// preserves received order for inspection; OCapN equality ignores it.
	Struct(Vec<(String, Argument)>),
}

impl Argument {
	/// The integer, if this is an [`Argument::Integer`] (an `i64`-range value;
	/// a larger OCapN integer arrives as [`Argument::BigInteger`]).
	pub fn as_i64(&self) -> Option<i64> {
		match self {
			Argument::Integer(v) => Some(*v),
			_ => None,
		}
	}

	/// The float, if this is an [`Argument::Float`].
	pub fn as_f64(&self) -> Option<f64> {
		match self {
			Argument::Float(v) => Some(*v),
			_ => None,
		}
	}

	/// The boolean, if this is an [`Argument::Boolean`].
	pub fn as_bool(&self) -> Option<bool> {
		match self {
			Argument::Boolean(v) => Some(*v),
			_ => None,
		}
	}

	/// The text, if this is an [`Argument::String`].
	pub fn as_str(&self) -> Option<&str> {
		match self {
			Argument::String(s) => Some(s),
			_ => None,
		}
	}

	/// The bytes, if this is an [`Argument::Bytes`].
	pub fn as_bytes(&self) -> Option<&[u8]> {
		match self {
			Argument::Bytes(b) => Some(b),
			_ => None,
		}
	}

	/// The element list, if this is an [`Argument::List`].
	pub fn as_list(&self) -> Option<&[Argument]> {
		match self {
			Argument::List(items) => Some(items),
			_ => None,
		}
	}

	/// Whether this is [`Argument::Void`] (the OCapN void / "no value").
	pub fn is_void(&self) -> bool {
		matches!(self, Argument::Void)
	}
}

// Native-value conversions so an argument list reads as plain Rust values:
// `&[42.into(), "hi".into(), (&cap).into()]`. Integers and floats each take a
// single concrete impl (`i64`, `f64`) so a bare literal still infers, `5.into()`
// is unambiguous. `Ref` already converts in `session.rs`.
impl From<i64> for Argument {
	fn from(v: i64) -> Argument {
		Argument::Integer(v)
	}
}

impl From<f64> for Argument {
	fn from(v: f64) -> Argument {
		Argument::Float(v)
	}
}

impl From<bool> for Argument {
	fn from(v: bool) -> Argument {
		Argument::Boolean(v)
	}
}

impl From<&str> for Argument {
	fn from(v: &str) -> Argument {
		Argument::String(v.to_string())
	}
}

impl From<String> for Argument {
	fn from(v: String) -> Argument {
		Argument::String(v)
	}
}

impl From<Vec<u8>> for Argument {
	fn from(v: Vec<u8>) -> Argument {
		Argument::Bytes(v)
	}
}

impl From<&[u8]> for Argument {
	fn from(v: &[u8]) -> Argument {
		Argument::Bytes(v.to_vec())
	}
}

impl From<()> for Argument {
	fn from(_: ()) -> Argument {
		Argument::Void
	}
}

impl From<Ref> for Argument {
	fn from(r: Ref) -> Argument {
		Argument::Reference(r)
	}
}

impl From<Vec<Argument>> for Argument {
	fn from(items: Vec<Argument>) -> Argument {
		Argument::List(items)
	}
}

/// Owns nested C argument arrays for the duration of one send call. The leaf
/// byte pointers borrow the source [`Argument`]'s own heap payloads (a
/// `String`/`Vec` buffer is address-stable when the enum value moves), so the
/// marshalled tree stays valid as long as the source value and this arena both
/// live.
#[cfg(feature = "async")]
#[derive(Default)]
pub(crate) struct SendArena {
	boxes: Vec<Box<[sys::PancakeArgument]>>,
}

#[cfg(feature = "async")]
impl SendArena {
	pub(crate) fn build(&mut self, args: &[Argument]) -> Result<(*const sys::PancakeArgument, usize)> {
		let mut out = Vec::with_capacity(args.len());
		for a in args {
			out.push(self.one(a)?);
		}
		let boxed = out.into_boxed_slice();
		let ptr = boxed.as_ptr();
		let len = boxed.len();
		self.boxes.push(boxed);
		Ok((ptr, len))
	}

	pub(crate) fn one(&mut self, a: &Argument) -> Result<sys::PancakeArgument> {
		let mut c: sys::PancakeArgument = unsafe { core::mem::zeroed() };
		match a {
			Argument::Integer(v) => {
				c.kind = sys::ARG_INTEGER;
				c.integer = *v;
			}
			Argument::Float(v) => {
				c.kind = sys::ARG_FLOAT64;
				c.float64 = *v;
			}
			Argument::Boolean(v) => {
				c.kind = sys::ARG_BOOLEAN;
				c.boolean = u32::from(*v);
			}
			Argument::Bytes(b) => set_bytes(&mut c, sys::ARG_BYTES, b),
			Argument::String(s) => set_bytes(&mut c, sys::ARG_STRING, s.as_bytes()),
			Argument::Symbol(s) => set_bytes(&mut c, sys::ARG_SYMBOL, s.as_bytes()),
			Argument::Error(message) => set_bytes(&mut c, sys::ARG_ERROR, message.as_bytes()),
			Argument::Void => c.kind = sys::ARG_VOID,
			Argument::Reference(r) => {
				c.kind = sys::ARG_REFERENCE;
				c.reference = r.to_sys()?;
			}
			Argument::List(items) => {
				c.kind = sys::ARG_LIST;
				let (ptr, len) = self.build(items)?;
				c.items = ptr;
				c.items_len = len;
			}
			Argument::Set(items) => {
				c.kind = sys::ARG_SET;
				let (ptr, len) = self.build(items)?;
				c.items = ptr;
				c.items_len = len;
			}
			Argument::Tagged { tag, value } => {
				c.kind = sys::ARG_TAGGED;
				c.bytes = tag.as_ptr();
				c.bytes_len = tag.len();
				let (ptr, len) = self.build(value)?;
				c.items = ptr;
				c.items_len = len;
			}
			Argument::Keyword(s) => set_bytes(&mut c, sys::ARG_KEYWORD, s.as_bytes()),
			Argument::BigInteger { negative, digits } => {
				set_bytes(&mut c, sys::ARG_BIG_INTEGER, digits.as_bytes());
				c.boolean = u32::from(*negative);
			}
			Argument::Struct(entries) => {
				c.kind = sys::ARG_STRUCT;
				let mut flat = Vec::with_capacity(entries.len() * 2);
				for (key, value) in entries {
					let mut key_arg: sys::PancakeArgument = unsafe { core::mem::zeroed() };
					set_bytes(&mut key_arg, sys::ARG_STRING, key.as_bytes());
					flat.push(key_arg);
					flat.push(self.one(value)?);
				}
				let boxed = flat.into_boxed_slice();
				c.items = boxed.as_ptr();
				c.items_len = boxed.len();
				self.boxes.push(boxed);
			}
		}
		Ok(c)
	}
}

// A Rust slice's pointer is non-null even at length zero (`NonNull`'s dangling
// stand-in), so a zero-length byte view — a methodless positional verb, an
// empty payload — marshals as the non-NULL `ptr + 0` the host requires, with
// no special case here.
#[cfg(feature = "async")]
fn set_bytes(c: &mut sys::PancakeArgument, kind: u32, b: &[u8]) {
	c.kind = kind;
	c.bytes = b.as_ptr();
	c.bytes_len = b.len();
}

/// Project a received C argument tree into owned Rust values.
///
/// # Safety
/// `c` must point to a valid `PancakeArgument` whose borrowed views are live
/// for the duration of the call.
#[cfg(feature = "async")]
pub(crate) unsafe fn arg_from_sys(c: &sys::PancakeArgument) -> Result<Argument> {
	Ok(match c.kind {
		sys::ARG_INTEGER => Argument::Integer(c.integer),
		sys::ARG_FLOAT64 => Argument::Float(c.float64),
		sys::ARG_BOOLEAN => Argument::Boolean(c.boolean != 0),
		sys::ARG_BYTES => Argument::Bytes(bytes_from_sys(c)),
		sys::ARG_STRING => Argument::String(String::from_utf8_lossy(&bytes_from_sys(c)).into_owned()),
		sys::ARG_SYMBOL => Argument::Symbol(String::from_utf8_lossy(&bytes_from_sys(c)).into_owned()),
		sys::ARG_ERROR => Argument::Error(String::from_utf8_lossy(&bytes_from_sys(c)).into_owned()),
		sys::ARG_REFERENCE => Argument::Reference(Ref::from_sys(&c.reference)),
		sys::ARG_LIST => Argument::List(args_from_sys(c.items, c.items_len)?),
		sys::ARG_SET => Argument::Set(args_from_sys(c.items, c.items_len)?),
		sys::ARG_TAGGED => Argument::Tagged {
			tag: String::from_utf8_lossy(&bytes_from_sys(c)).into_owned(),
			value: args_from_sys(c.items, c.items_len)?,
		},
		sys::ARG_KEYWORD => Argument::Keyword(String::from_utf8_lossy(&bytes_from_sys(c)).into_owned()),
		sys::ARG_VOID => Argument::Void,
		sys::ARG_BIG_INTEGER => Argument::BigInteger {
			negative: c.boolean != 0,
			digits: String::from_utf8_lossy(&bytes_from_sys(c)).into_owned(),
		},
		sys::ARG_STRUCT => {
			let flat = args_from_sys(c.items, c.items_len)?;
			if flat.len() % 2 != 0 {
				return Err(Error::with_detail(
					sys::ERR_INTERNAL,
					"pancake ABI returned an odd Struct item count".into(),
				));
			}
			let mut entries = Vec::with_capacity(flat.len() / 2);
			let mut it = flat.into_iter();
			while let Some(key) = it.next() {
				let Argument::String(key) = key else {
					return Err(Error::with_detail(
						sys::ERR_INTERNAL,
						"pancake ABI returned a non-String Struct key".into(),
					));
				};
				let value = it.next().expect("even Struct item count");
				entries.push((key, value));
			}
			Argument::Struct(entries)
		}
		other => {
			return Err(Error::with_detail(
				sys::ERR_INTERNAL,
				format!("pancake ABI returned unknown argument kind {other}"),
			))
		}
	})
}

#[cfg(feature = "async")]
unsafe fn bytes_from_sys(c: &sys::PancakeArgument) -> Vec<u8> {
	owned_from_view(c.bytes, c.bytes_len)
}

/// Copy a borrowed C byte view (`ptr`, `len`) into an owned `Vec`, guarding the
/// null/empty case: `core::slice::from_raw_parts` requires a non-null pointer
/// even for `len == 0`, so a null `bytes` on a successful dequeue becomes an
/// empty `Vec` here rather than instant UB.
///
/// # Safety
/// When `ptr` is non-null and `len > 0`, it must point to `len` initialized,
/// readable bytes valid for the duration of the call.
#[cfg(any(feature = "async", feature = "tcp", feature = "inproc"))]
pub(crate) unsafe fn owned_from_view(ptr: *const u8, len: usize) -> Vec<u8> {
	if ptr.is_null() || len == 0 {
		Vec::new()
	} else {
		core::slice::from_raw_parts(ptr, len).to_vec()
	}
}

/// Project a borrowed C argument array into owned Rust values.
///
/// # Safety
/// `ptr` must point to `len` valid `PancakeArgument`s (or be null) whose
/// borrowed views are live for the duration of the call.
#[cfg(feature = "async")]
pub(crate) unsafe fn args_from_sys(ptr: *const sys::PancakeArgument, len: usize) -> Result<Vec<Argument>> {
	if ptr.is_null() {
		return Ok(Vec::new());
	}
	(0..len).map(|i| arg_from_sys(&*ptr.add(i))).collect()
}

/// The wire codec a host's sessions speak and a TCP connection frames with. Both
/// ends of a connection must use the same value.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Codec {
	Syrup,
	Capnp,
}

impl Codec {
	#[cfg(any(feature = "async", feature = "tcp", feature = "inproc"))]
	pub(crate) fn to_c(self) -> u32 {
		match self {
			Codec::Syrup => sys::CODEC_SYRUP,
			Codec::Capnp => sys::CODEC_CAPNP,
		}
	}
}

/// The CapTP profile a session speaks (ADR-0003). `V1_0` is the interop floor a
/// Goblins vat and the upstream suite speak; `Next` is the pancake-to-pancake
/// track that `Offer::native` prefers together with Cap'n Proto. A Host states
/// its preference in signed locator hints; each session settles the pair with
/// its partner.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum CaptpVersion {
	#[default]
	V1_0,
	Next,
}

impl CaptpVersion {
	pub(crate) fn to_c(self) -> u32 {
		match self {
			CaptpVersion::V1_0 => sys::CAPTP_V1_0,
			CaptpVersion::Next => sys::CAPTP_NEXT,
		}
	}
}

/// Optional CapTP features a Host advertises during profile negotiation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FeatureSet(u32);

impl FeatureSet {
	pub const MINIMUM: FeatureSet = FeatureSet(sys::FEATURE_MINIMUM);
	pub const BASELINE: FeatureSet = FeatureSet(sys::FEATURE_BASELINE);
	pub const PIPELINING: FeatureSet = FeatureSet(sys::FEATURE_PIPELINING);
	pub const HANDOFF: FeatureSet = FeatureSet(sys::FEATURE_HANDOFF);
	pub const WIRE_DELTA: FeatureSet = FeatureSet(sys::FEATURE_WIRE_DELTA);
	pub const STURDYREF: FeatureSet = FeatureSet(sys::FEATURE_STURDYREF);
	pub const UNTAG: FeatureSet = FeatureSet(sys::FEATURE_UNTAG);
	pub const FULL: FeatureSet = FeatureSet(sys::FEATURE_FULL);

	pub const fn from_bits(bits: u32) -> Option<FeatureSet> {
		if bits & !sys::FEATURE_FULL == 0 {
			Some(FeatureSet(bits))
		} else {
			None
		}
	}

	pub const fn bits(self) -> u32 {
		self.0
	}

	pub const fn contains(self, feature: FeatureSet) -> bool {
		(self.0 & feature.0) == feature.0
	}

	#[cfg(feature = "async")]
	pub(crate) const fn to_c(self) -> u32 {
		self.0
	}
}

impl core::ops::BitOr for FeatureSet {
	type Output = FeatureSet;

	fn bitor(self, rhs: FeatureSet) -> FeatureSet {
		FeatureSet(self.0 | rhs.0)
	}
}

impl core::ops::BitOrAssign for FeatureSet {
	fn bitor_assign(&mut self, rhs: FeatureSet) {
		self.0 |= rhs.0;
	}
}

impl Default for FeatureSet {
	fn default() -> Self {
		FeatureSet::FULL
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn archive_fingerprint_refuses_a_stale_callable_surface() {
		require_archive_fingerprint("test", 0x1234, 0x1234).unwrap();
		let error = require_archive_fingerprint("test", 0x5678, 0x1234).unwrap_err();
		assert_eq!(error.kind(), ErrorKind::Internal);
		assert!(error.message().unwrap().contains("callable surface does not match"));
		assert!(error.message().unwrap().contains("rebuild the native libraries"));
	}

	#[cfg(feature = "async")]
	#[test]
	fn unknown_native_classifications_are_returned_failures() {
		assert_eq!(lifecycle_is_closed(sys::LIFECYCLE_ACTIVE).unwrap(), false);
		assert_eq!(lifecycle_is_closed(sys::LIFECYCLE_CLOSED).unwrap(), true);
		assert_eq!(lifecycle_is_closed(u32::MAX).unwrap_err().kind(), ErrorKind::Internal);
		assert_eq!(AbortDomain::from_abi(u32::MAX).unwrap_err().kind(), ErrorKind::Internal);
		assert_eq!(
			FailureLayer::from_abi(u32::MAX).unwrap_err().kind(),
			ErrorKind::Internal
		);
		assert_eq!(
			FailureScope::from_abi(u32::MAX).unwrap_err().kind(),
			ErrorKind::Internal
		);
	}

	// The public `ErrorKind` maps each known `PANCAKE_ERR_*` family, and an
	// unknown or retired code falls through to `Other` with the raw value, so the
	// enum cannot silently diverge from a code a consumer still sees.
	#[test]
	fn error_kind_names_the_families() {
		assert_eq!(Error::from_code(sys::ERR_BROKEN).kind(), ErrorKind::Broken);
		assert_eq!(Error::from_code(sys::ERR_IO).kind(), ErrorKind::Io);
		assert_eq!(Error::from_code(sys::ERR_CLOSED).kind(), ErrorKind::Closed);
		assert_eq!(
			Error::from_code(sys::ERR_FRAME_TOO_LARGE).kind(),
			ErrorKind::FrameTooLarge
		);
		assert_eq!(
			Error::from_code(sys::ERR_UNSUPPORTED_VALUE).kind(),
			ErrorKind::UnsupportedValue
		);
		assert_eq!(
			Error::from_code(sys::ERR_BUFFER_TOO_SMALL).kind(),
			ErrorKind::BufferTooSmall
		);
		// A code outside every known family falls through to Other, carrying the
		// raw value so a consumer can still read it.
		let unrecognized = -999;
		assert_eq!(Error::from_code(unrecognized).kind(), ErrorKind::Other(unrecognized));
	}

	#[test]
	fn arguments_convert_from_and_into_native_rust_values() {
		// Build an argument list out of plain Rust values, literals infer.
		let args: Vec<Argument> = vec![42.into(), 3.5.into(), true.into(), "hi".into(), ().into()];
		assert_eq!(args[0].as_i64(), Some(42));
		assert_eq!(args[1].as_f64(), Some(3.5));
		assert_eq!(args[2].as_bool(), Some(true));
		assert_eq!(args[3].as_str(), Some("hi"));
		assert!(args[4].is_void());

		// Owned and borrowed forms both convert.
		assert_eq!(Argument::from(String::from("yo")).as_str(), Some("yo"));
		assert_eq!(Argument::from(vec![1u8, 2, 3]).as_bytes(), Some(&[1, 2, 3][..]));
		assert_eq!(Argument::from(b"hi".as_slice()).as_bytes(), Some(&b"hi"[..]));

		// A mismatched accessor is `None`, never a panic.
		assert_eq!(Argument::Boolean(true).as_str(), None);
	}

	#[test]
	fn reports_a_nonzero_abi_version() {
		let (major, minor, patch) = abi_version();
		assert!(major + minor + patch > 0);
	}

	#[test]
	fn context_claims_the_cross_language_failure_vector_once() {
		let context = Context::new().unwrap();
		let operation = b"listener.close";
		let primary_name = b"CloseFailed";
		let primary_message = b"socket refused shutdown";
		let secondary_name = b"ReleaseFailed";
		let secondary_message = b"descriptor remained live";
		let report = sys::PancakeFailureReport {
			abi_version: 1,
			struct_size: core::mem::size_of::<sys::PancakeFailureReport>(),
			layer: abi_constants_gen::FAILURE_LAYER_TRANSPORT,
			scope_kind: abi_constants_gen::FAILURE_SCOPE_LISTENER,
			scope_id: 31,
			operation_id: 47,
			primary_result: sys::ERR_IO,
			secondary_result: sys::ERR_INTERNAL,
			secondary_count: 2,
			operation: operation.as_ptr(),
			operation_len: operation.len(),
			primary_name: primary_name.as_ptr(),
			primary_name_len: primary_name.len(),
			primary_message: primary_message.as_ptr(),
			primary_message_len: primary_message.len(),
			secondary_name: secondary_name.as_ptr(),
			secondary_name_len: secondary_name.len(),
			secondary_message: secondary_message.as_ptr(),
			secondary_message_len: secondary_message.len(),
		};
		check(unsafe { sys::pancake_context_report_failure(context.inner.raw, &report) }).unwrap();

		let failures = context.take_failures().unwrap();
		assert_eq!(failures.len(), 1);
		let failure = &failures[0];
		assert_eq!(failure.sequence, 1);
		assert_eq!(failure.dropped_before, 0);
		assert_eq!(failure.layer, FailureLayer::Transport);
		assert_eq!(failure.scope, FailureScope::Listener);
		assert_eq!(failure.scope_id, 31);
		assert_eq!(failure.operation_id, 47);
		assert_eq!(failure.primary_result, sys::ERR_IO);
		assert_eq!(failure.secondary_result, sys::ERR_INTERNAL);
		assert_eq!(failure.secondary_count, 2);
		assert_eq!(failure.operation, "listener.close");
		assert_eq!(failure.primary_name, "CloseFailed");
		assert_eq!(failure.primary_message, "socket refused shutdown");
		assert_eq!(failure.secondary_name, "ReleaseFailed");
		assert_eq!(failure.secondary_message, "descriptor remained live");
		assert!(context.next_failure().unwrap().is_none());
	}

	#[cfg(feature = "async")]
	#[test]
	fn runtime_failure_journal_is_typed_bounded_and_saturation_aware() {
		// Saturation is a property of one journal. Exercise a private instance so
		// parallel tests may legitimately report to the process journal without
		// changing this proof's loss count or consuming its records.
		let mut journal = RuntimeFailureJournal::new();
		for index in 0..=RUNTIME_FAILURE_CAP {
			journal.record(
				FailureLayer::Binding,
				"test-drop",
				Error::with_detail(sys::ERR_INTERNAL, format!("failure {index}")),
			);
		}
		let diagnostics = journal.claim();
		assert_eq!(diagnostics.len(), RUNTIME_FAILURE_CAP);
		assert_eq!(diagnostics[0].dropped_before, 1);
		assert!(diagnostics.iter().all(|failure| failure.operation == "test-drop"));
		assert_eq!(diagnostics[0].primary_message, "failure 1");

		journal.record(
			FailureLayer::Binding,
			"test-payload-bound",
			Error::with_detail(sys::ERR_INTERNAL, "x".repeat(FAILURE_PAYLOAD_CAP * 2)),
		);
		let bounded = journal.claim().pop().unwrap();
		assert_ne!(bounded.truncated_fields & (1 << 2), 0);
		assert!(
			bounded.operation.len()
				+ bounded.primary_name.len()
				+ bounded.primary_message.len()
				+ bounded.secondary_name.len()
				+ bounded.secondary_message.len()
				<= FAILURE_PAYLOAD_CAP
		);

		let _serial = RUNTIME_FAILURE_TEST_LOCK
			.lock()
			.unwrap_or_else(std::sync::PoisonError::into_inner);
		take_runtime_failures();
		let context = Context::new().unwrap();
		let original = Error::with_detail(-99, "observer failed".to_owned());
		context.inner.report_failure(
			FailureLayer::ApplicationObserver,
			FailureScope::Host,
			17,
			0,
			"trace.sink",
			&original,
		);
		let fallback = take_runtime_failures();
		let original = fallback
			.iter()
			.find(|failure| failure.operation == "trace.sink")
			.expect("original recorder refusal reaches the process seam");
		assert_eq!(original.layer, FailureLayer::ApplicationObserver);
		assert_eq!(original.primary_message, "observer failed");
		let recorder = fallback
			.iter()
			.find(|failure| failure.operation == "diagnostic.record")
			.expect("recorder failure reaches the process seam");
		assert_eq!(recorder.layer, FailureLayer::Binding);
		assert_eq!(recorder.primary_result, sys::ERR_INVALID_ARGUMENT);
	}

	#[cfg(feature = "async")]
	#[test]
	fn allocator_panics_are_contained_and_diagnosed() {
		struct PanickingAllocator;

		impl ContextAllocator for PanickingAllocator {
			fn alloc(&self, _size: usize, _alignment: usize) -> *mut u8 {
				panic!("allocator alloc panic");
			}

			unsafe fn free(&self, _ptr: *mut u8, _size: usize, _alignment: usize) {
				panic!("allocator free panic");
			}
		}

		let _serial = RUNTIME_FAILURE_TEST_LOCK
			.lock()
			.unwrap_or_else(std::sync::PoisonError::into_inner);
		take_runtime_failures();
		let allocator: Box<dyn ContextAllocator> = Box::new(PanickingAllocator);
		let user_data = &allocator as *const Box<dyn ContextAllocator> as *mut core::ffi::c_void;
		let allocated = unsafe { alloc_trampoline(user_data, 8, 8) };
		assert!(allocated.is_null());
		unsafe { free_trampoline(user_data, core::ptr::NonNull::<u8>::dangling().as_ptr().cast(), 8, 8) };

		let diagnostics = take_runtime_failures();
		assert!(diagnostics.iter().any(|failure| {
			failure.operation == "context-allocator-alloc-panic" && failure.primary_message == "allocator alloc panic"
		}));
		assert!(diagnostics.iter().any(|failure| {
			failure.operation == "context-allocator-free-panic" && failure.primary_message == "allocator free panic"
		}));
	}

	#[test]
	fn feature_sets_compose_as_masks() {
		let mut features = FeatureSet::PIPELINING | FeatureSet::HANDOFF;
		assert!(features.contains(FeatureSet::PIPELINING));
		assert!(features.contains(FeatureSet::HANDOFF));
		assert!(!features.contains(FeatureSet::STURDYREF));
		assert!(!FeatureSet::BASELINE.contains(FeatureSet::UNTAG));
		assert!(FeatureSet::FULL.contains(FeatureSet::UNTAG));

		features |= FeatureSet::WIRE_DELTA;
		assert_eq!(
			features.bits(),
			(sys::FEATURE_PIPELINING | sys::FEATURE_HANDOFF | sys::FEATURE_WIRE_DELTA)
		);
		assert_eq!(FeatureSet::from_bits(features.bits()), Some(features));
		assert_eq!(FeatureSet::from_bits(sys::FEATURE_FULL | 0x100), None);
	}

	// A marshalled argument round-trips through the C layout: the send arena
	// builds the C tree over borrowed payloads and the lift copies it back into
	// owned values, so the two halves of the boundary agree on every kind.
	// `SendArena` and `arg_from_sys` are both behind `async`, so this rides the
	// same feature: without it the test target does not compile at all, which
	// makes a plain `cargo test` fail before it runs anything.
	#[cfg(feature = "async")]
	#[test]
	fn arguments_round_trip_through_the_c_layout() {
		let original = Argument::List(vec![
			Argument::Integer(7),
			Argument::Error("failure is a value".into()),
			Argument::String("hi".into()),
			Argument::Bytes(vec![1, 2, 3]),
			Argument::Tagged {
				tag: "point".into(),
				value: vec![Argument::Integer(3), Argument::Integer(4)],
			},
			Argument::Keyword("color".into()),
			Argument::BigInteger {
				negative: false,
				digits: "1208925819614629174706176".into(),
			},
			Argument::Struct(vec![
				("name".into(), Argument::String("widget".into())),
				("count".into(), Argument::Integer(3)),
			]),
			Argument::Reference(Ref::bare_id(5)),
			Argument::Void,
		]);
		let mut arena = SendArena::default();
		let c = arena.one(&original).unwrap();
		let lifted = unsafe { arg_from_sys(&c) }.unwrap();
		assert_eq!(lifted, original);
	}

	#[cfg(feature = "async")]
	#[test]
	fn unknown_native_argument_kind_is_a_returned_failure() {
		let mut c = unsafe { core::mem::zeroed::<sys::PancakeArgument>() };
		c.kind = u32::MAX;
		let error = unsafe { arg_from_sys(&c) }.expect_err("unknown argument kind must be rejected");
		assert_eq!(error.code(), sys::ERR_INTERNAL);
		assert!(error.message().unwrap_or_default().contains("unknown argument kind"));
	}
}
