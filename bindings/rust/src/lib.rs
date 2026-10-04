//! Idiomatic Rust API for glowcap — an OCapN/CapTP [`Host`] whose partners
//! you hold as a [`Session`].
//!
//! The shared raw C ABI lives in the private `sys` module. The one deliberate
//! exception is `webrtc`, whose public contract is the native companion
//! archive's multiplexed readiness and try-I/O boundary.
//! What you use is the application surface every glowcap binding speaks —
//! [`Runtime::connect`] plus transport-module `listen`, a [`Session`] with `fetch`/`send`/`tell`/
//! `spawn`/`publish`, one opaque [`Ref`] capability type, a Rust [`Argument`]
//! enum, and `Result` for fallible calls — over the symbol-disjoint
//! `libglowcap_host` and `libglowcap_driver` archives (ADR-0112). The Host
//! archive owns `glowcap_host_*`; the driver exports only `glowcap_driver_*`
//! and adopts a quiescent Host. Bounded `iroh`, `noise-tcp`, `keyed-tcp`, `tcp`, and routed relay dials and
//! listeners ride the loop (`driver_loop`); a quiescent caller-supplied Host
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
//! glowcap's C ABI ships as a set of symbol-disjoint archives (ADR-0059), and
//! this crate mirrors that shape: the core value/locator vocabulary and the
//! Host ABI is always available at the crate root, and each optional transport
//! is a module behind a Cargo feature that links exactly its archive — you pay
//! (in linked archive and symbols) only for the transports you enable. The
//! core stands alone; the transport modules build on it but never on each
//! other.
//!
//! | Feature | Module | Archive linked | Default |
//! | --- | --- | --- | --- |
//! | (always) | crate root + [`Locator`] | `libglowcap_ocapn` + `libglowcap_host` + `libglowcap_driver` | yes |
//! | `tcp` | [`tcp`] | `libglowcap_net_transport_tcp` | yes |
//! | `inproc` | `inproc` | `libglowcap_net_transport_inproc` | yes |
//! | `onion` | `onion` | `libglowcap_net_transport_onion` | no |
//! | `iroh` | `iroh` | `libglowcap_net_transport_iroh` (dynamic) | no |
//! | `relay` | `relay` | `libglowcap_net_transport_relay` | no |
//! | `webrtc` | `webrtc` | `libglowcap_net_transport_webrtc` (dynamic) | no |
//! | `async` | [`Session`], [`Host`], [`Runtime`] | (none — shared byte-fed execution) | no |
//! | `browser` | `browser` (Wasm only) | (none — browser platform I/O) | no |
//!
//! `tcp` and `inproc` are on by default. `onion` is opt-in because it needs a Tor
//! daemon the deployment runs; glowcap starts none. `iroh` is opt-in and implies `async`
//! (the tokio driver it rides); it needs the companion library built by
//! `zig build iroh-abi`. The `async` feature adds the tokio-driven
//! [`Session`] over byte streams and links no transport archive of its own.
//! Native targets add the socket reactor; Wasm targets use browser entropy and
//! timers while the embedder polls a Tokio LocalSet and supplies byte channels.

#[cfg(feature = "loam")]
pub mod loam;

mod abi_constants;
// Reflected ABI constants (`zig build gen-binding-constants`); re-exported
// through `abi_constants`.
mod abi_constants_gen;

#[cfg(all(target_arch = "wasm32", feature = "browser"))]
pub mod browser;

#[cfg(feature = "async")]
mod execution;
#[cfg(feature = "async")]
mod session;
#[cfg(feature = "async")]
mod session_shared;
#[cfg(feature = "async")]
pub use session::{
	AcceptedTransport, ChannelDesignator, DurableProvenance, HANDSHAKE_TIMEOUT, PartnerIdentity, SendRedeemingResult,
	Session,
};
#[cfg(feature = "async")]
pub use session_shared::Caretaker;
#[cfg(feature = "async")]
pub use trampoline::current_session;
#[cfg(feature = "async")]
mod finalizer;
#[cfg(feature = "async")]
mod host;
#[cfg(feature = "async")]
mod lifecycle;
#[cfg(feature = "async")]
mod trace;
#[cfg(feature = "async")]
pub use host::{Host, HostOptions, ListenerIdentity, Resolver, SessionLimitOptions};
#[cfg(feature = "async")]
pub use lifecycle::PendingWork;
#[cfg(feature = "async")]
pub use trace::{PayloadSummary, SessionMeta, TraceEvent, TraceKind, TraceSink, annotate_session, enable_trace};
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
mod channel;
#[cfg(feature = "async")]
mod connector;
#[cfg(feature = "async")]
pub use channel::{Channel, ChannelClose, PacketRead, PacketWrite};
#[cfg(feature = "async")]
mod dial;
#[cfg(feature = "async")]
mod runtime;
// The one binding owner of a generic driver listener, shared by every
// transport that hosts through the driver archive.
#[cfg(all(
	feature = "async",
	any(feature = "tcp", feature = "iroh", feature = "onion", feature = "relay")
))]
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

// Every glowcap archive keeps its own thread-local last-error slot (ADR-0059);
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
pub mod tcp;

// The iroh transport (its own optional companion library, ADR-0055): the
// encrypted-QUIC byte-stream bridge the `Session` pump carries a session over.
#[cfg(all(feature = "async", not(target_arch = "wasm32")))]
mod driver_event;
#[cfg(all(feature = "async", not(target_arch = "wasm32")))]
mod driver_failure;
/// Native `DriverLoop` tier and the route used by `Runtime` transports.
#[cfg(all(feature = "async", not(target_arch = "wasm32")))]
pub mod driver_loop;
#[cfg(feature = "async")]
pub use connector::{Connector, DialOrigin, TransportOperationOptions};
#[cfg(feature = "iroh")]
pub mod iroh;
#[cfg(feature = "webrtc")]
pub mod webrtc;

// OCapN locator URIs, core libglowcap_ocapn vocabulary, so a TCP-only consumer reaches
// the grammar without the iroh companion library. One grammar, no hand-rolled
// percent codec. Transport packages construct typed locators; this module owns
// their generic model and explicit URI conversion.
mod uri;
pub use uri::{
	HintValue, HintWireForm, Locator, SturdyRef, designator_host_port, encode_peer_locator, format_locator_uri,
	format_peer_uri, format_sturdyref, parse_locator, parse_sturdyref,
};

/// OCapN transport / hint vocabulary; mirrors `model.transport.*`.
pub use abi_constants::{
	HINT_ALT_LOCATORS, HINT_DIRECT_ADDRESSES, HINT_VIA, TRANSPORT_ID, TRANSPORT_INPROC, TRANSPORT_IROH,
	TRANSPORT_KEYED_RELAY, TRANSPORT_KEYED_TCP, TRANSPORT_NOISE_RELAY, TRANSPORT_NOISE_TCP, TRANSPORT_ONION,
	TRANSPORT_TCP, TRANSPORT_WEBRTC,
};

/// Browser ICE configuration envelopes, generated from the transport ABI.
pub use abi_constants::{
	WEBRTC_MAX_ICE_CREDENTIAL_BYTES, WEBRTC_MAX_ICE_SERVERS, WEBRTC_MAX_ICE_URL_BYTES, WEBRTC_MAX_ICE_URLS_PER_SERVER,
};

/// Shared admission budgets for hosts forwarding opaque relay traffic.
pub use abi_constants::{BINDING_RELAY_MAX_BYTES_PER_SESSION, BINDING_RELAY_TCP_DIAL_TIMEOUT_MS};

mod carrier_failure;
mod sys;
pub use carrier_failure::{CarrierFailure, CarrierPhase};
mod runtime_failure;
#[cfg(all(test, feature = "async"))]
pub(crate) use runtime_failure::RUNTIME_FAILURE_TEST_LOCK;
#[cfg(test)]
pub(crate) use runtime_failure::{FAILURE_PAYLOAD_CAP, RUNTIME_FAILURE_CAP, RuntimeFailureJournal};

/// An actor behavior: handle a `(verb, args)` call, returning a reply or an
/// error message (which becomes a broken answer carrying those words). This is
/// what [`Session::spawn`]/[`Session::publish`] host and what a
/// [`Host::publish_giftable`] factory mints.
pub type Behavior = Box<dyn FnMut(&str, &[Argument]) -> std::result::Result<Argument, String>>;

mod failure;
pub(crate) use failure::require_archive_fingerprint;
pub use failure::{AbortDomain, AbortInfo, Error, ErrorKind, Result, take_runtime_failures};
#[cfg(feature = "async")]
pub(crate) use failure::{lifecycle_is_closed, retain_cleanup_failure};
pub(crate) use failure::{panic_message, record_runtime_failure};
mod diagnostic;
pub use diagnostic::{FailureEvent, FailureLayer, FailureScope};
mod context;
#[cfg(feature = "async")]
pub(crate) use context::ContextInner;
pub(crate) use context::check;
pub use context::{Context, ContextAllocator, abi_version, last_error};
#[cfg(test)]
pub(crate) use context::{alloc_trampoline, free_trampoline};
mod value;
#[cfg(any(feature = "async", feature = "tcp", feature = "inproc", feature = "onion"))]
pub(crate) use value::owned_from_view;
pub use value::{Argument, Ref};
#[cfg(feature = "async")]
pub(crate) use value::{SendArena, arg_from_sys, args_from_sys};
mod profile;
pub use profile::{CaptpVersion, Codec, FeatureSet, HostProfile, SessionProfile};
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
		assert!(!lifecycle_is_closed(sys::LIFECYCLE_ACTIVE).unwrap());
		assert!(lifecycle_is_closed(sys::LIFECYCLE_CLOSED).unwrap());
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

	// The public `ErrorKind` maps each known `GLOWCAP_ERR_*` family, and an
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
		let report = sys::GlowcapFailureReport {
			abi_version: 1,
			struct_size: core::mem::size_of::<sys::GlowcapFailureReport>(),
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
		check(unsafe { sys::glowcap_context_report_failure(context.inner.raw, &report) }).unwrap();

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
		let mut c = unsafe { core::mem::zeroed::<sys::GlowcapArgument>() };
		c.kind = u32::MAX;
		let error = unsafe { arg_from_sys(&c) }.expect_err("unknown argument kind must be rejected");
		assert_eq!(error.code(), sys::ERR_INTERNAL);
		assert!(error.message().unwrap_or_default().contains("unknown argument kind"));
	}
}
