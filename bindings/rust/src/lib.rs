//! Idiomatic Rust API for pancake — an OCapN/CapTP [`Host`] whose partners
//! you hold as a [`Session`].
//!
//! The raw C ABI lives in the private `sys` module; nothing in it escapes.
//! What you use is the application surface every pancake binding speaks —
//! [`connect`]/[`listen`], a [`Session`] with `fetch`/`send`/`tell`/
//! `spawn`/`publish`, a [`Ref`] capability, real Rust enums for
//! [`Reference`]/[`Argument`], and `Result` for fallible calls — over the
//! byte-fed host archive `libpancake_driver` (ADR-0072). The [`Host`] owns
//! `engine.Node` (router) and every CapTP decision; Goblins' `mycapn` is two
//! roles — endpoint ≈ Host, router tables ≈ `engine.Node` (ADR-0079). This
//! crate moves bytes and honors the host's action queue. This is the dogfood
//! consumer `zig build rust-dogfood` runs, so the ergonomic surface stays
//! honest.
//!
//! # Composable modules, à la carte
//!
//! pancake's C ABI ships as a set of symbol-disjoint archives (ADR-0059), and
//! this crate mirrors that shape: the core value/locator vocabulary and the
//! byte-fed host are always available at the crate root, and each transport is
//! a module behind a Cargo feature that links exactly its archive — you pay
//! (in linked archive and symbols) only for the transports you enable. The
//! core stands alone; the transport modules build on it but never on each
//! other.
//!
//! | Feature | Module | Archive linked | Default |
//! | --- | --- | --- | --- |
//! | (always) | crate root + [`Locator`] | `libpancake_ocapn` + `libpancake_driver` | yes |
//! | `tcp` | [`tcp`] | `libpancake_net_transport_tcp` | yes |
//! | `inproc` | [`inproc`] | `libpancake_net_transport_inproc` | yes |
//! | `iroh` | [`iroh`] | `libpancake_net_transport_iroh` (dynamic) | no |
//! | `async` | [`Session`], [`Host`], [`connect`]/[`listen`] | (none — native tokio) | no |
//!
//! `tcp` and `inproc` are on by default. `iroh` is opt-in and implies `async`
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
pub use session::{Redeemed, Session, HANDSHAKE_TIMEOUT};
#[cfg(feature = "async")]
pub use session_shared::{Caretaker, Ref};
#[cfg(feature = "async")]
mod host;
#[cfg(feature = "async")]
pub use host::{Host, HostOptions};
#[cfg(feature = "async")]
mod trampoline;
// Byte-fed embedder pump: feed / flush / serve-loop / feed-refusal (crate-private).
#[cfg(feature = "async")]
mod pump;
// Host action decode + execute: pop / run (crate-private).
#[cfg(feature = "async")]
mod action;
// RemotePromise + send-target plumbing (Pass 3a).
#[cfg(feature = "async")]
mod promise;
#[cfg(feature = "async")]
pub use promise::{AsSendTarget, RemotePromise};
// Distributed GC (ADR-0063) ImportGuard + drain (Pass 3b).
#[cfg(feature = "async")]
mod gc;
// Dial executor: plan + channel open + connect (Pass 3c).
#[cfg(feature = "async")]
mod dial;
// Server / listen / keyed-tcp host (Pass 3d).
#[cfg(feature = "async")]
mod listen;
#[cfg(feature = "async")]
pub use listen::{listen, listen_keyed_tcp, listen_with_host, KeyedTcpServer, Server};
// Generated HostAction kinds + decode (`zig build gen-binding-host-action`).
#[cfg(feature = "async")]
mod host_action_gen;

// `connect` is the one dialer over an `ocapn://` locator, with one signature
// across every build: `connect(uri, reachability, host)`. A `tcp` locator ignores the
// reachability (pass `None`); an `iroh` locator requires it. `host` shares one
// identity for handoffs on `tcp` / `keyed-tcp`. Without the iroh
// feature the dialer still takes the reachability argument — so an `async` consumer's call
// site never changes when iroh is turned on — and an `iroh` locator fails with a
// rebuild hint instead of dialing. A tcp-only consumer therefore never links the
// iroh companion library, yet writes the same call as an iroh-enabled one. Both
// dialers bound the OCapN handshake; `connect_with_timeout` is the one that
// lets the caller name the budget.
#[cfg(feature = "async")]
pub use dial::{connect, connect_with_timeout, Reachability};
#[cfg(feature = "iroh")]
pub use iroh::{listen_iroh, listen_iroh_with_seed, IrohServer};

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
#[cfg(feature = "tcp")]
pub mod tcp;

// The iroh transport (its own optional companion library, ADR-0055): the
// encrypted-QUIC byte-stream bridge the `Session` pump carries a session over.
#[cfg(feature = "iroh")]
pub mod iroh;

// OCapN locator URIs, core libpancake_ocapn vocabulary, so a TCP-only consumer reaches
// the grammar without the iroh companion library. One grammar, no hand-rolled
// percent codec. `tcp_locator` and `encode_peer_locator` are pure grammar over
// the always-linked core too, so they ship in every build, async or not.
mod uri;
pub use uri::{
	designator_host_port, encode_peer_locator, format_peer_uri, keyed_tcp_locator, parse_locator,
	parse_sturdyref, socket_addr_designator, tcp_locator, Locator,
};

/// OCapN transport / hint vocabulary; mirrors `model.transport.*`.
pub use abi_constants::{
	HINT_DIRECT_ADDRESSES, TRANSPORT_INPROC, TRANSPORT_IROH, TRANSPORT_KEYED_TCP, TRANSPORT_TCP,
};

mod sys;

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
	pub(crate) fn from_abi(domain: u32) -> Self {
		match domain {
			abi_constants::ABORT_DOMAIN_CODEC => AbortDomain::Codec,
			abi_constants::ABORT_DOMAIN_SESSION => AbortDomain::Session,
			_ => AbortDomain::Foreign,
		}
	}
}

/// The typed cause of a connection's most recent local dispatch failure, the
/// safe projection of `pancake_host_session_last_abort`. The flat `PANCAKE_ERR_*`
/// code names the failure family; this names the member: which layer refused,
/// the projected `op:abort` kind when one applies, and the diagnostic strings.
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
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
	code: i32,
	detail: Option<String>,
	abort: Option<AbortInfo>,
}

impl Error {
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

	fn from_code(code: i32) -> Error {
		// Snapshot the thread-local message now, while it still belongs to the
		// call that just failed, matching the Python/Deno/Racket bindings.
		Error {
			code,
			detail: last_error(),
			abort: None,
		}
	}

	/// A binding-side failure with an explicit message, for a refusal the C ABI
	/// never saw (e.g. an `ocapn://` URI naming a transport this build cannot dial).
	#[cfg(feature = "async")]
	fn with_detail(code: i32, detail: String) -> Error {
		Error {
			code,
			detail: Some(detail),
			abort: None,
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
	std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
		let allocator = &*(user_data as *const Box<dyn ContextAllocator>);
		allocator.alloc(size, alignment) as *mut core::ffi::c_void
	}))
	.unwrap_or(core::ptr::null_mut())
}

unsafe extern "C" fn free_trampoline(
	user_data: *mut core::ffi::c_void,
	ptr: *mut core::ffi::c_void,
	size: usize,
	alignment: usize,
) {
	let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
		let allocator = &*(user_data as *const Box<dyn ContextAllocator>);
		allocator.free(ptr as *mut u8, size, alignment);
	}));
}

/// An allocation scope. Hosts and netlayers created in a context route every
/// allocation through it. Release order matters: drop the context only after
/// every handle created in it. Released on drop.
pub struct Context {
	pub(crate) raw: *mut sys::PancakeContext,
	// Kept alive (and freed after `pancake_context_release`) for the custom
	// allocator path; null for the default-allocator context.
	allocator: *mut Box<dyn ContextAllocator>,
}

impl Context {
	/// A context backed by the library-owned allocator.
	pub fn new() -> Result<Context> {
		let mut raw: *mut sys::PancakeContext = core::ptr::null_mut();
		check(unsafe { sys::pancake_context_new(&mut raw) })?;
		Ok(Context {
			raw,
			allocator: core::ptr::null_mut(),
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
			raw,
			allocator: user_data,
		})
	}
}

impl Drop for Context {
	fn drop(&mut self) {
		// Release the context first — it frees its tables through the allocator —
		// then drop the host allocator the trampolines borrowed.
		unsafe { sys::pancake_context_release(self.raw) };
		if !self.allocator.is_null() {
			unsafe { drop(Box::from_raw(self.allocator)) };
		}
	}
}

/// A capability reference.
#[derive(Debug, Clone, PartialEq)]
pub enum Reference {
	/// A local export this session hosts.
	Near {
		id: u64,
		promise: bool,
	},
	/// A partner-hosted capability this host holds, under a node-unique token
	/// (ADR-0069) — the id the application sees is never a raw wire position.
	Far {
		id: u64,
		promise: bool,
	},
	/// A pipeline promise on an answer.
	Promise {
		answer: u64,
	},
	Sturdy,
	Broken,
}

impl Reference {
	/// The common case: call a partner object you hold as import `id`.
	pub fn far(id: u64) -> Reference {
		Reference::Far { id, promise: false }
	}
}

/// The wire identity a capability in hand takes: a local `Near` export or a
/// partner-held `Far` token. These are the only two shapes a [`Ref`] holds. A
/// pipeline promise is a [`RemotePromise`], and a sturdyref or broken reference
/// arrives as a plain wire value, so those three [`Reference`] variants are
/// unconstructible here. This mirrors the Python binding's `Near | Far` and
/// makes a `Ref`'s `near`/`far` views total: exactly one is set.
#[derive(Debug, Clone, PartialEq)]
pub enum LiveRef {
	/// A local export this session hosts.
	Near { id: u64, promise: bool },
	/// A partner-held capability this host holds.
	Far { id: u64, promise: bool },
}

impl LiveRef {
	/// Widen to the full wire [`Reference`] for marshaling.
	pub fn reference(&self) -> Reference {
		match *self {
			LiveRef::Near { id, promise } => Reference::Near { id, promise },
			LiveRef::Far { id, promise } => Reference::Far { id, promise },
		}
	}
}

impl TryFrom<&Reference> for LiveRef {
	type Error = ();

	/// A capability is a `Near` or a `Far`; a promise, sturdyref, or broken
	/// reference is not one, and lifts to `Err`.
	fn try_from(r: &Reference) -> std::result::Result<LiveRef, ()> {
		match *r {
			Reference::Near { id, promise } => Ok(LiveRef::Near { id, promise }),
			Reference::Far { id, promise } => Ok(LiveRef::Far { id, promise }),
			_ => Err(()),
		}
	}
}

// The C marshaling layer: used only by the async host tier, so it compiles
// only with it — dead-code linting stays live instead of blanket-allowed.
#[cfg(feature = "async")]
impl Reference {
	pub(crate) fn to_sys(&self) -> Result<sys::PancakeReference> {
		let (kind, sub, id) = match *self {
			Reference::Near { id, promise } => (sys::REF_NEAR, sub(promise), id),
			Reference::Far { id, promise } => (sys::REF_FAR, sub(promise), id),
			Reference::Promise { answer } => (sys::REF_PROMISE, 0, answer),
			Reference::Sturdy | Reference::Broken => {
				return Err(Error::from_code(sys::ERR_UNSUPPORTED_VALUE))
			}
		};
		Ok(sys::PancakeReference {
			kind,
			sub_kind: sub,
			id,
		})
	}

	pub(crate) fn from_sys(r: &sys::PancakeReference) -> Reference {
		let promise = r.sub_kind == sys::REF_SUB_PROMISE;
		match r.kind {
			sys::REF_NEAR => Reference::Near { id: r.id, promise },
			sys::REF_FAR => Reference::Far { id: r.id, promise },
			sys::REF_PROMISE => Reference::Promise { answer: r.id },
			sys::REF_STURDY => Reference::Sturdy,
			_ => Reference::Broken,
		}
	}
}

#[cfg(feature = "async")]
fn sub(promise: bool) -> u32 {
	if promise {
		sys::REF_SUB_PROMISE
	} else {
		sys::REF_SUB_OBJECT
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
	Void,
	Reference(Reference),
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

impl From<Reference> for Argument {
	fn from(r: Reference) -> Argument {
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
	pub(crate) fn build(
		&mut self,
		args: &[Argument],
	) -> Result<(*const sys::PancakeArgument, usize)> {
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
pub(crate) unsafe fn arg_from_sys(c: &sys::PancakeArgument) -> Argument {
	match c.kind {
		sys::ARG_INTEGER => Argument::Integer(c.integer),
		sys::ARG_FLOAT64 => Argument::Float(c.float64),
		sys::ARG_BOOLEAN => Argument::Boolean(c.boolean != 0),
		sys::ARG_BYTES => Argument::Bytes(bytes_from_sys(c)),
		sys::ARG_STRING => {
			Argument::String(String::from_utf8_lossy(&bytes_from_sys(c)).into_owned())
		}
		sys::ARG_SYMBOL => {
			Argument::Symbol(String::from_utf8_lossy(&bytes_from_sys(c)).into_owned())
		}
		sys::ARG_REFERENCE => Argument::Reference(Reference::from_sys(&c.reference)),
		sys::ARG_LIST => Argument::List(args_from_sys(c.items, c.items_len)),
		sys::ARG_SET => Argument::Set(args_from_sys(c.items, c.items_len)),
		sys::ARG_TAGGED => Argument::Tagged {
			tag: String::from_utf8_lossy(&bytes_from_sys(c)).into_owned(),
			value: args_from_sys(c.items, c.items_len),
		},
		sys::ARG_KEYWORD => {
			Argument::Keyword(String::from_utf8_lossy(&bytes_from_sys(c)).into_owned())
		}
		sys::ARG_VOID => Argument::Void,
		sys::ARG_BIG_INTEGER => Argument::BigInteger {
			negative: c.boolean != 0,
			digits: String::from_utf8_lossy(&bytes_from_sys(c)).into_owned(),
		},
		// The C ABI kind set is closed (0..=12); any other value is the C ABI and
		// this binding drifting out of sync. Fail loud where a test would catch
		// it rather than silently decoding a future kind as Void.
		other => {
			debug_assert!(false, "unknown PancakeArgument kind {other} from the C ABI");
			Argument::Void
		}
	}
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
pub(crate) unsafe fn args_from_sys(ptr: *const sys::PancakeArgument, len: usize) -> Vec<Argument> {
	if ptr.is_null() {
		return Vec::new();
	}
	(0..len).map(|i| arg_from_sys(&*ptr.add(i))).collect()
}

/// The wire codec a host's sessions speak and a TCP endpoint frames with. Both
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

#[cfg(test)]
mod tests {
	use super::*;

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
		assert_eq!(
			Error::from_code(unrecognized).kind(),
			ErrorKind::Other(unrecognized)
		);
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
		assert_eq!(
			Argument::from(vec![1u8, 2, 3]).as_bytes(),
			Some(&[1, 2, 3][..])
		);
		assert_eq!(
			Argument::from(b"hi".as_slice()).as_bytes(),
			Some(&b"hi"[..])
		);

		// A mismatched accessor is `None`, never a panic.
		assert_eq!(Argument::Boolean(true).as_str(), None);
	}

	#[test]
	fn reports_a_nonzero_abi_version() {
		let (major, minor, patch) = abi_version();
		assert!(major + minor + patch > 0);
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
			Argument::Reference(Reference::far(5)),
			Argument::Void,
		]);
		let mut arena = SendArena::default();
		let c = arena.one(&original).unwrap();
		let lifted = unsafe { arg_from_sys(&c) };
		assert_eq!(lifted, original);
	}
}
