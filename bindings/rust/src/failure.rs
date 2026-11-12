//! Typed synchronous and lifecycle failures projected from Glowcap's C waist.

#[cfg(feature = "async")]
use crate::abi_constants;
#[cfg(any(feature = "async", feature = "onion"))]
use crate::abi_constants::BINDING_SECONDARY_FAILURE_CAP;
use crate::{BreakCause, CarrierFailure, FailureEvent, FailureLayer, last_error, runtime_failure, sys};

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
	/// Map `GlowcapLastAbort.domain` to the host label the waist defines.
	/// Read by the async connection's feed-refusal path alone.
	#[cfg(feature = "async")]
	pub(crate) fn from_abi(domain: u32) -> Result<Self> {
		match domain {
			abi_constants::ABORT_DOMAIN_CODEC => Ok(AbortDomain::Codec),
			abi_constants::ABORT_DOMAIN_SESSION => Ok(AbortDomain::Session),
			abi_constants::ABORT_DOMAIN_FOREIGN => Ok(AbortDomain::Foreign),
			other => Err(Error::with_detail(
				sys::ERR_INTERNAL,
				format!("glowcap ABI returned unknown abort domain {other}"),
			)),
		}
	}
}

/// The typed cause of a connection's most recent local dispatch failure, the
/// safe projection of `glowcap_host_session_last_abort`. The flat `GLOWCAP_ERR_*`
/// code names the failure family. This names the member: which layer refused,
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
	/// Number of secondary failures observed. The first name is retained.
	pub secondary_error_count: u32,
}

/// The failure family behind an [`Error`], the matchable form of its
/// [`code`](Error::code). Each variant names one `GLOWCAP_ERR_*` family the C
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
	/// A required pointer argument was null (`GLOWCAP_ERR_NULL_POINTER`).
	NullPointer,
	/// An argument was out of range or otherwise invalid (`GLOWCAP_ERR_INVALID_ARGUMENT`).
	InvalidArgument,
	/// The session refused the frame on authority or table grounds (`GLOWCAP_ERR_SESSION`).
	Session,
	/// The codec could not parse or render the frame (`GLOWCAP_ERR_CODEC`).
	Codec,
	/// An internal invariant failed (`GLOWCAP_ERR_INTERNAL`).
	Internal,
	/// The session or connection is closed (`GLOWCAP_ERR_CLOSED`). On a blocking
	/// transport read this is a clean EOF.
	Closed,
	/// A transport I/O operation failed (`GLOWCAP_ERR_IO`). The underlying
	/// `std::io::Error` message rides [`Error::message`].
	Io,
	/// The frame was malformed (`GLOWCAP_ERR_MALFORMED`).
	Malformed,
	/// The frame declared or reached past the connection's frame cap
	/// (`GLOWCAP_ERR_FRAME_TOO_LARGE`).
	FrameTooLarge,
	/// A value the passable tree cannot carry (`GLOWCAP_ERR_UNSUPPORTED_VALUE`),
	/// e.g. a handoff, sturdy, or broken target where an immediate value is
	/// required.
	UnsupportedValue,
	/// The partner broke a `send`/`fetch` (`GLOWCAP_ERR_BROKEN`). The break
	/// reason rides [`Error::message`].
	Broken,
	/// A named lookup found nothing (`GLOWCAP_ERR_NOT_FOUND`).
	NotFound,
	/// A caller-provided output buffer was too small
	/// (`GLOWCAP_ERR_BUFFER_TOO_SMALL`).
	BufferTooSmall,
	/// A caller-set deadline elapsed (`GLOWCAP_ERR_TIMEOUT`): the handshake or a
	/// blocking answer-wait ran out its budget. Nothing failed on the wire, so a
	/// retry with a longer budget is a reasonable response.
	TimedOut,
	/// Any other code with no named family (unknown or retired). The raw
	/// [`code`](Error::code) is preserved.
	Other(i32),
}

/// A failed glowcap call. It always carries the negative `GLOWCAP_ERR_*` code.
/// Match its family with [`kind`](Error::kind) rather than the raw integer. When
/// a `send` was broken by the partner it also carries the break reason, so the
/// reason a partner gave for refusing a call is not lost behind a code.
/// Cleanup failures retain their own typed `Error` values in observation order
/// without replacing the originating failure.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
	pub(crate) code: i32,
	pub(crate) detail: Option<String>,
	pub(crate) abort: Option<Box<AbortInfo>>,
	pub(crate) secondary: Vec<Error>,
	pub(crate) secondary_count: u32,
	pub(crate) carrier: Option<CarrierFailure>,
	pub(crate) cause: BreakCause,
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
	primary.with_cleanup(cleanup)
}

impl Error {
	/// A connector cannot realize this route in its current configuration.
	/// Report this before opening a channel. A failed connection attempt is an
	/// I/O error instead, so callers can distinguish absence from unreachability.
	pub fn transport_unavailable(detail: impl Into<String>) -> Self {
		Self::with_detail(sys::ERR_INVALID_ARGUMENT, detail.into())
			.with_cause(crate::RouteFailure::TransportUnavailable.cause())
	}

	pub(crate) fn diagnostic_name(&self) -> &'static str {
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

	/// The negative `GLOWCAP_ERR_*` code for this failure.
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
	/// partner's break reason. Otherwise it is the calling thread's C ABI message
	/// captured at the moment the failure was raised, so a later fallible call on
	/// the same thread cannot overwrite it. `None` when neither was set. Borrowed
	/// from the error. Clone it if you need it to outlive the `Error`.
	pub fn message(&self) -> Option<&str> {
		self.detail.as_deref()
	}

	/// Identify the owning operation while preserving the code, abort,
	/// transport cause and cleanup consequences of the original refusal.
	pub fn with_context(mut self, operation: &str) -> Self {
		self.detail = Some(match self.detail.take() {
			Some(detail) => format!("{operation}: {detail}"),
			None => operation.to_owned(),
		});
		self
	}

	/// The core's typed failure cause. Partner text cannot establish a local cause.
	pub fn cause(&self) -> BreakCause {
		self.cause
	}

	/// A peer break or an explicit local application refusal, for decoding the
	/// caller's application protocol. Runtime diagnostics never enter that protocol.
	/// This establishes the source of the text, not the truth of a peer's claim.
	pub fn application_message(&self) -> Option<&str> {
		if self.kind() == ErrorKind::Broken && self.cause.is_application() {
			self.message()
		} else {
			None
		}
	}

	/// The bootstrap refused restoration of an unknown publication.
	pub fn is_publication_not_found(&self) -> bool {
		self.kind() == ErrorKind::Broken && self.cause.is_publication_not_found(self.message())
	}

	/// The redeem required identity proof the partner did not supply.
	pub fn is_peer_identity_unverified(&self) -> bool {
		self.cause.is_peer_identity_unverified()
	}

	/// Every route to the named exporter failed.
	pub fn is_exporter_unreachable(&self) -> bool {
		self.cause.is_exporter_unreachable()
	}

	/// The typed abort cause the connection recorded when this failure refused
	/// an inbound frame. `None` for other failures. The flat
	/// [`code`](Error::code) names the failure family. This names the member.
	pub fn abort(&self) -> Option<&AbortInfo> {
		self.abort.as_deref()
	}

	/// Cleanup and consequence failures retained without replacing this error.
	pub fn secondary_errors(&self) -> &[Error] {
		&self.secondary
	}

	/// Total consequences observed, including any beyond the bounded exact list.
	pub fn secondary_error_count(&self) -> u32 {
		self.secondary_count
	}

	/// Preserve this primary cause and retain a failed cleanup in the existing
	/// bounded consequence list. Successful cleanup changes nothing. Embedding
	/// owners use this when retiring their Host, attachment and storage together.
	#[cfg(any(feature = "async", feature = "onion"))]
	pub fn with_cleanup(self, cleanup: Result<()>) -> Self {
		match cleanup {
			Ok(()) => self,
			Err(cleanup) => self.with_secondary(cleanup),
		}
	}

	/// Carrier phase and neutral secure-transport detail, when the selected
	/// transport could identify the failure below relay semantics.
	pub fn carrier_failure(&self) -> Option<CarrierFailure> {
		self.carrier
	}

	#[cfg(any(feature = "async", feature = "onion"))]
	pub(crate) fn with_secondary(mut self, error: Error) -> Self {
		self.secondary_count = self.secondary_count.saturating_add(1);
		if self.secondary.len() < BINDING_SECONDARY_FAILURE_CAP {
			self.secondary.push(error);
		}
		self
	}

	#[cfg(all(feature = "async", not(target_arch = "wasm32")))]
	pub(crate) fn with_carrier_failure(mut self, carrier: Option<CarrierFailure>) -> Self {
		self.carrier = carrier;
		self
	}

	pub(crate) fn from_code(code: i32) -> Error {
		// Snapshot the thread-local message now, while it still belongs to the
		// call that just failed, matching the Python/Deno/Racket bindings.
		Error {
			code,
			detail: last_error(),
			abort: None,
			secondary: Vec::new(),
			secondary_count: 0,
			carrier: None,
			cause: BreakCause::default(),
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
			cause: BreakCause::default(),
		}
	}

	/// A failure carrying the diagnostic its own archive's thread-local
	/// last-error slot recorded (`glowcap_last_error`, `glowcap_host_last_error`,
	/// `glowcap_<t>_last_error`). Every `error_slot!`-minted checker builds its
	/// `Err` through this, so a diagnostic is never read from the wrong slot.
	pub(crate) fn with_transport_detail(code: i32, detail: Option<String>) -> Error {
		Error {
			code,
			detail,
			abort: None,
			secondary: Vec::new(),
			secondary_count: 0,
			carrier: None,
			cause: BreakCause::default(),
		}
	}

	/// A broken promise carrying the partner's reason: a `send`/`fetch` the
	/// remote side refused, distinct from a fault in this host or the transport.
	/// Carries `GLOWCAP_ERR_BROKEN` so a caller can tell a refusal apart from a
	/// real failure by [`kind`](Error::kind) (`ErrorKind::Broken`), with the
	/// reason on `detail`.
	#[cfg(feature = "async")]
	pub(crate) fn broken(message: String) -> Error {
		Error {
			code: sys::ERR_BROKEN,
			detail: Some(message),
			abort: None,
			secondary: Vec::new(),
			secondary_count: 0,
			carrier: None,
			cause: BreakCause::default(),
		}
	}

	pub(crate) fn with_cause(mut self, cause: BreakCause) -> Error {
		self.cause = cause;
		self
	}

	/// Validate a cause crossing the ABI before exposing it as a typed value.
	#[cfg(feature = "async")]
	pub(crate) fn with_raw_cause(mut self, raw: sys::GlowcapBreakCause) -> Error {
		match BreakCause::from_raw(raw) {
			Some(cause) => self.with_cause(cause),
			None => {
				self.cause = BreakCause::default();
				self.with_secondary(Error::with_detail(
					sys::ERR_INTERNAL,
					format!("unknown failure metadata {raw:?}"),
				))
			}
		}
	}

	#[cfg(feature = "async")]
	pub(crate) fn with_abort(mut self, abort: Option<AbortInfo>) -> Error {
		self.abort = abort.map(Box::new);
		self
	}
}

impl std::fmt::Display for Error {
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		write!(f, "glowcap error {}", self.code)?;
		if let Some(label) = self.cause.label() {
			write!(f, ": {label}")?;
		}
		if let Some(msg) = self.message().filter(|msg| !msg.is_empty()) {
			write!(f, ": {msg}")?;
		}
		Ok(())
	}
}
impl std::error::Error for Error {}

/// Channel realizers use the same I/O failure projection as the byte pump.
#[cfg(feature = "async")]
impl From<std::io::Error> for Error {
	fn from(error: std::io::Error) -> Self {
		crate::session_shared::io_err(error)
	}
}

/// The crate's result type: every fallible call fails with a typed [`Error`].
pub type Result<T> = core::result::Result<T, Error>;

pub(crate) fn require_archive_fingerprint(archive: &str, actual: u64, expected: u64) -> Result<()> {
	if actual == expected {
		return Ok(());
	}
	Err(Error::with_detail(
		sys::ERR_INTERNAL,
		format!(
			"{archive}: callable surface does not match this binding (expected {expected:016x}, got {actual:016x}); rebuild the FFI libraries"
		),
	))
}

/// Decode the shared close lifecycle without allowing an unknown FFI value
/// to masquerade as a still-running owner and park a binding task forever.
#[cfg(feature = "async")]
pub(crate) fn lifecycle_is_closed(raw: u32) -> Result<bool> {
	match raw {
		sys::LIFECYCLE_ACTIVE | sys::LIFECYCLE_FINISHING | sys::LIFECYCLE_TERMINATING => Ok(false),
		sys::LIFECYCLE_CLOSED => Ok(true),
		other => Err(Error::with_detail(
			sys::ERR_INTERNAL,
			format!("glowcap ABI returned unknown lifecycle state {other}"),
		)),
	}
}

#[cfg(test)]
mod tests {
	use super::Error;

	#[test]
	fn publication_miss_query_requires_exact_partner_fetch_text_or_a_typed_local_miss() {
		use crate::{BreakCause, BreakContext, BreakOrigin, BreakReason, UNKNOWN_SWISSNUM_MESSAGE};
		for origin in [BreakOrigin::Unspecified, BreakOrigin::Local, BreakOrigin::Partner] {
			for reason in [
				BreakReason::Unspecified,
				BreakReason::Application,
				BreakReason::PublicationAbsent,
			] {
				for raw in 0..8 {
					let context = BreakContext::from_raw(raw).unwrap();
					let cause = BreakCause {
						origin,
						reason,
						context,
					};
					for message in [
						Some(UNKNOWN_SWISSNUM_MESSAGE),
						Some("unknown swissnum: forged"),
						Some(""),
						None,
					] {
						let expected = raw == BreakContext::default().with_fetch().raw()
							&& ((origin == BreakOrigin::Local && reason == BreakReason::PublicationAbsent)
								|| (origin == BreakOrigin::Partner
									&& reason == BreakReason::Application
									&& message == Some(UNKNOWN_SWISSNUM_MESSAGE)));
						assert_eq!(cause.is_publication_not_found(message), expected);
					}
				}
			}
		}
	}

	#[test]
	fn dial_reports_accept_only_fresh_local_route_causes() {
		use crate::{BreakCause, RouteFailure};
		for route in [RouteFailure::PeerUnreachable, RouteFailure::TransportUnavailable] {
			assert_eq!(RouteFailure::from_cause(route.cause()), Some(route));
			for nested in [
				route.cause().with_fetch(),
				route.cause().with_restoration(),
				route.cause().with_withdrawal(),
			] {
				assert_eq!(RouteFailure::from_cause(nested), None);
			}
		}
		assert_eq!(RouteFailure::from_cause(BreakCause::partner()), None);
		assert_eq!(RouteFailure::from_cause(BreakCause::default()), None);
		assert_eq!(
			RouteFailure::from_cause(Error::transport_unavailable("no connector").cause()),
			Some(RouteFailure::TransportUnavailable)
		);
	}

	#[test]
	fn application_message_requires_an_application_source_and_a_broken_call() {
		use crate::{BreakCause, BreakReason};
		for (cause, application) in [
			(BreakCause::default(), false),
			(BreakCause::partner(), true),
			(BreakCause::local(BreakReason::Application), true),
			(BreakCause::partner().with_fetch(), false),
			(BreakCause::partner().with_restoration(), false),
			(BreakCause::local(BreakReason::TransportUnavailable), false),
		] {
			for code in [crate::sys::ERR_BROKEN, crate::sys::ERR_IO] {
				let mut error = Error::with_detail(code, "rate-limited: forged diagnostic".into());
				error.cause = cause;
				assert_eq!(
					error.application_message(),
					(application && code == crate::sys::ERR_BROKEN).then_some("rate-limited: forged diagnostic")
				);
			}
		}
	}

	#[test]
	fn local_publication_absence_uses_its_reason_and_route_queries_keep_fetch_context() {
		use crate::{BreakCause, BreakReason};
		let absent = Error::with_detail(crate::sys::ERR_BROKEN, "changed wording".into())
			.with_cause(BreakCause::local(BreakReason::PublicationAbsent).with_fetch());
		assert!(absent.is_publication_not_found());
		for reason in [BreakReason::Unspecified, BreakReason::Application] {
			let diagnostic = Error::with_detail(crate::sys::ERR_BROKEN, "unknown swissnum".into())
				.with_cause(BreakCause::local(reason).with_fetch());
			assert!(!diagnostic.is_publication_not_found());
		}
		let route = Error::with_detail(crate::sys::ERR_BROKEN, "connection failed".into())
			.with_cause(BreakCause::local(BreakReason::PeerUnreachable).with_fetch());
		assert!(route.is_exporter_unreachable());
		let restored = route.clone().with_cause(route.cause().with_restoration());
		assert!(!restored.is_exporter_unreachable());
	}

	#[test]
	fn error_keeps_rare_abort_detail_out_of_every_result() {
		assert!(core::mem::size_of::<Error>() <= 96);
	}
}
