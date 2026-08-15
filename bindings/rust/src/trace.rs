//! The live timeline producer: a veneer over the native tap. The core is the
//! one owner of the facts — `pancake_host_set_trace` reports every session's
//! open (with the partner's designator, whether a durable identity verified
//! the name, and the codec the handshake actually negotiated), every
//! message's verb in both directions, and every close. This veneer only
//! stamps time and forwards one flat record per fact in the versioned
//! timeline schema; even endpoint labeling belongs to the consumer (ocapnviz
//! resolves src/dst from the session-opened it already saw), so nothing here
//! keeps per-session state.
//!
//! Off by default and zero-cost when off: with no sink installed nothing is
//! registered with the core, so its emit sites are one null check.
//!
//! One thread drives one Host in this binding, and the sink registry follows:
//! everything here is thread-local, like the Hosts themselves.

use std::cell::RefCell;
use std::ffi::c_void;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::rc::Rc;
use std::time::Instant;

use crate::abi_constants_gen::{
	CAPTP_NEXT, CAPTP_V1_0, CODEC_CAPNP, CODEC_SYRUP, TRACE_MESSAGE, TRACE_SESSION_CLOSE, TRACE_SESSION_OPEN,
};
use crate::session::DurableProvenance;
use crate::sys::host as ffi;

/// One wire event in the versioned timeline schema (`{v:1, sim_t_ns, kind, …}`).
#[derive(Debug, Clone)]
pub struct TraceEvent {
	pub sim_t_ns: u64,
	pub kind: TraceKind,
	/// This producer's own handle for the session, host-qualified because a
	/// core session id is host-scoped. Not the OCapN Session ID: that is
	/// `session_id` below, which both ends of one session derive alike and
	/// which is therefore the only one that can merge two producers' views.
	pub session: String,
	/// `SessionOpened`: the two ends and the negotiated codec. `a` is this
	/// host's own OCapN Designator, which is what a partner names it by, so
	/// one peer stays one node in a feed several producers share; `b` the
	/// partner's Designator.
	pub a: Option<String>,
	pub b: Option<String>,
	/// `SessionOpened`: the OCapN Transport of `b`'s locator. A designator
	/// does not name a location on its own — the spec requires designator and
	/// transport together to tell two locations apart.
	pub transport: Option<String>,
	/// `SessionOpened`: what the reporting host would like itself called on
	/// screen. Display only — `a` stays the identity a consumer merges on,
	/// and this text does not reach that decision.
	pub a_label: Option<String>,
	/// `SessionOpened`: the implementation this producer runs, always
	/// `"pancake"` here. A statement about the producer, beside the designator
	/// it calls itself by and the label it would like to be shown under, and on
	/// the same footing as the `provenance` verdict below: a conclusion the
	/// producer states rather than a raw wire fact.
	///
	/// It is stated because this schema is not pancake's alone — the Goblins
	/// conformance peer publishes the same records — so a consumer cannot read
	/// an implementation off the fact that a record arrived, and a host that
	/// says nothing is honestly unknown to it.
	pub a_profile: Option<&'static str>,
	/// `SessionOpened`: the OCapN Session ID, 64 lowercase hex digits. Both
	/// peers of one session derive the same value, so a consumer merging feeds
	/// can tell that two producers are watching one session rather than two
	/// unrelated ones. None when the partner sent no session key.
	pub session_id: Option<String>,
	pub codec: Option<&'static str>,
	/// `SessionOpened`: the negotiated CapTP profile by its wire spelling
	/// (`"1.0"` / `"pancake-next"`). Reported beside the codec because the
	/// two are one decision (ADR-0003).
	pub captp_version: Option<&'static str>,
	/// `SessionOpened`: what proved the partner's durable name. Three answers
	/// rather than a yes/no: a partner that claimed no durable name and one
	/// whose claim nothing on its path could prove are different facts.
	pub provenance: DurableProvenance,
	/// `MessageDecoded`: direction and verb. Endpoint labels resolve at the
	/// consumer from the session's open.
	pub outbound: bool,
	pub op: Option<String>,
	/// `MessageDecoded`: the wire frame's true byte length, when the core
	/// reported the frame (inbound messages; an outbound send is traced
	/// before its deferred encode).
	pub len: Option<usize>,
	/// The whole frame, base64, when it fits `PAYLOAD_CAP`.
	pub bytes_b64: Option<String>,
	/// The frame's head when it outgrew the cap: `len` is the true length,
	/// `head_b64` the first cap bytes.
	pub summary: Option<PayloadSummary>,
	/// `MessageDecoded`: a tag over the frame's bytes, lowercase hex, naming
	/// this one message across the two peers that carried it. One frame
	/// crosses one wire, so both ends derive the same tag from the bytes they
	/// hold, with no coordination. A consumer watching a session from both
	/// ends folds their two sightings into one message on this.
	pub digest: Option<String>,
	/// `SessionMeta`: the application's annotation.
	pub meta: Option<SessionMeta>,
}

/// A capped payload: the frame's true length plus its base64 head.
#[derive(Debug, Clone)]
pub struct PayloadSummary {
	pub len: usize,
	pub head_b64: String,
}

/// Payload bytes forwarded per message (whole frame under the cap, head +
/// true length above it). The TypeScript veneer exposes this as an
/// `enableTrace` option; make it configurable here when a consumer asks.
const PAYLOAD_CAP: usize = 4096;

/// What this producer answers when a record asks what it runs. A constant and
/// not an option: the host behind this binding is a pancake host, and letting
/// an application name itself something else would put a claim on the wire
/// that nothing here could stand behind.
///
/// Each of the four bindings states this word itself, because it is a claim
/// about the binding tier rather than a fact the core or the C ABI carries, so
/// there is no declaration to generate it from. `zig build source-check`
/// (`checkTraceViewerVocabulary`) holds all four against each other, against
/// the viewer that reads them, and against the Goblins conformance publisher,
/// which states a different word and must keep stating it.
const SELF_PROFILE: &str = "pancake";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TraceKind {
	SessionOpened,
	MessageDecoded,
	SessionClosed,
	/// An application annotation about the session (`annotate_session`).
	SessionMeta,
}

/// An application's claim about a session — see `annotate_session`.
#[derive(Debug, Clone)]
pub struct SessionMeta {
	pub label: String,
}

pub type TraceSink = Box<dyn Fn(&TraceEvent)>;

fn emit_record(context: &crate::ContextInner, diagnostic_id: u64, sink: Rc<dyn Fn(&TraceEvent)>, record: TraceEvent) {
	// Trace observation must not become protocol control flow. In particular,
	// Host-driving re-entry is refused by the C ABI, and a panic must never
	// cross the C callback.
	if let Err(payload) = catch_unwind(AssertUnwindSafe(|| sink(&record))) {
		context.report_failure(
			crate::FailureLayer::ApplicationObserver,
			crate::FailureScope::Host,
			diagnostic_id,
			0,
			"trace.sink",
			&crate::Error::with_detail(crate::sys::ERR_INTERNAL, crate::panic_message(payload.as_ref())),
		);
	}
}

/// Annotate a session with application metadata — the SET half of the
/// three-layer annotation channel (set where meaning lives, pass through
/// dumb, use at the edge): the application that knows what a session MEANS
/// (a chat server that knows which member it carries) states it here, and
/// the record rides the same stream as the protocol facts, named for the
/// same session row the tap names. An annotation is a claim, never
/// identity. No sink installed, or a host the trace never attached:
/// silently nothing, like every other trace emit.
pub fn annotate_session(session: &crate::Session, label: &str) {
	let (host_raw, session_raw) = session.trace_handles();
	if session_raw.is_null() {
		return;
	}
	let Some((context, diagnostic_id, sink, cookie, sim_t_ns)) = STATE.with(|state| {
		let state = state.borrow();
		let sink = state.sink.clone()?;
		let host = state.hosts.iter().find(|h| h.raw == host_raw)?;
		Some((
			Rc::clone(&host.context),
			host.diagnostic_id,
			sink,
			host.cookie,
			state.t0.elapsed().as_nanos() as u64,
		))
	}) else {
		return;
	};
	let mut id: u64 = 0;
	let code = unsafe { ffi::pancake_host_session_trace_id(session_raw, &mut id) };
	if code != 0 {
		return;
	}
	emit_record(
		&context,
		diagnostic_id,
		sink,
		TraceEvent {
			sim_t_ns,
			kind: TraceKind::SessionMeta,
			session: format!("live-h{cookie}-s{id}"),
			a: None,
			b: None,
			a_label: None,
			a_profile: None,
			transport: None,
			session_id: None,
			codec: None,
			captp_version: None,
			provenance: DurableProvenance::Unauthenticated,
			outbound: false,
			op: None,
			len: None,
			bytes_b64: None,
			summary: None,
			digest: None,
			meta: Some(SessionMeta {
				label: label.to_string(),
			}),
		},
	);
}

struct TracedHost {
	raw: *mut ffi::PancakeHost,
	/// The small integer passed as the callback ctx so a record can carry
	/// which host it came from (the Names rule: a bare host-scoped id needs
	/// its namespace named, or two hosts in one process collide).
	cookie: usize,
	/// The host's own key designator, which is what a partner names it by.
	designator: String,
	context: Rc<crate::ContextInner>,
	diagnostic_id: u64,
}

struct TraceState {
	sink: Option<Rc<dyn Fn(&TraceEvent)>>,
	/// Identifies the current installation so an older uninstall closure cannot
	/// disable a replacement sink.
	generation: u64,
	/// The display label the application chose for its own endpoint, or None.
	self_label: Option<String>,
	t0: Instant,
	hosts: Vec<TracedHost>,
	next_cookie: usize,
}

thread_local! {
	static STATE: RefCell<TraceState> = RefCell::new(TraceState {
		sink: None,
		generation: 0,
		self_label: None,
		t0: Instant::now(),
		hosts: Vec::new(),
		next_cookie: 1,
	});
}

fn view(ptr: *const u8, len: usize) -> Option<String> {
	if ptr.is_null() || len == 0 {
		return None;
	}
	let bytes = unsafe { std::slice::from_raw_parts(ptr, len) };
	Some(String::from_utf8_lossy(bytes).into_owned())
}

fn codec_from_abi(codec: u32) -> &'static str {
	if codec == CODEC_CAPNP {
		"capnp"
	} else if codec == CODEC_SYRUP {
		"syrup"
	} else {
		"unknown"
	}
}

fn captp_version_from_abi(version: u32) -> &'static str {
	if version == CAPTP_NEXT {
		"pancake-next"
	} else if version == CAPTP_V1_0 {
		"1.0"
	} else {
		"unknown"
	}
}

/// Standard base64 (RFC 4648, padded) of a small buffer — bounded by
/// `PAYLOAD_CAP`, so a dependency-free encoder beats a crate.
/// The message tag as lowercase hex. It rides the record inline rather than
/// behind a pointer, so there is nothing to borrow-check here.
fn hex(bytes: &[u8]) -> String {
	let mut out = String::with_capacity(bytes.len() * 2);
	for b in bytes {
		out.push_str(&format!("{b:02x}"));
	}
	out
}

fn base64(bytes: &[u8]) -> String {
	const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
	for chunk in bytes.chunks(3) {
		let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
		let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
		out.push(ALPHABET[(n >> 18) as usize & 63] as char);
		out.push(ALPHABET[(n >> 12) as usize & 63] as char);
		out.push(if chunk.len() > 1 {
			ALPHABET[(n >> 6) as usize & 63] as char
		} else {
			'='
		});
		out.push(if chunk.len() > 2 {
			ALPHABET[n as usize & 63] as char
		} else {
			'='
		});
	}
	out
}

unsafe extern "C" fn on_native_event(ctx: *mut c_void, event: *const ffi::PancakeTraceEvent) {
	let ev = unsafe { &*event };
	let Some((context, diagnostic_id, sink, record)) = STATE.with(|state| {
		let state = state.borrow();
		let sink = state.sink.clone()?;
		let sim_t_ns = state.t0.elapsed().as_nanos() as u64;
		let cookie = ctx as usize;
		let session = format!("live-h{}-s{}", cookie, ev.session);
		let record = match ev.kind {
			k if k == TRACE_SESSION_OPEN => TraceEvent {
				sim_t_ns,
				kind: TraceKind::SessionOpened,
				session,
				a: state
					.hosts
					.iter()
					.find(|h| h.cookie == cookie)
					.map(|h| h.designator.clone()),
				a_label: state.self_label.clone(),
				a_profile: Some(SELF_PROFILE),
				b: Some(view(ev.designator, ev.designator_len).unwrap_or_else(|| String::from("peer"))),
				transport: view(ev.transport, ev.transport_len),
				session_id: view(ev.session_id, ev.session_id_len),
				codec: Some(codec_from_abi(ev.codec)),
				captp_version: Some(captp_version_from_abi(ev.captp_version)),
				provenance: DurableProvenance::from_abi(ev.provenance),
				outbound: false,
				op: None,
				len: None,
				bytes_b64: None,
				summary: None,
				digest: None,
				meta: None,
			},
			k if k == TRACE_MESSAGE => {
				// The frame is borrowed for this call, so the payload copy
				// happens here or never: whole frame under the cap, head +
				// true length above it.
				let total_len = if ev.frame_total_len == 0 {
					ev.frame_len
				} else {
					ev.frame_total_len
				};
				let (len, bytes_b64, summary) = if total_len == 0 {
					(None, None, None)
				} else if !ev.frame.is_null() && ev.frame_len > 0 {
					let frame = unsafe { std::slice::from_raw_parts(ev.frame, ev.frame_len) };
					if total_len <= PAYLOAD_CAP && frame.len() >= total_len {
						(Some(total_len), Some(base64(&frame[..total_len])), None)
					} else {
						(
							Some(total_len),
							None,
							Some(PayloadSummary {
								len: total_len,
								head_b64: base64(&frame[..frame.len().min(PAYLOAD_CAP)]),
							}),
						)
					}
				} else {
					(Some(total_len), None, None)
				};
				TraceEvent {
					sim_t_ns,
					kind: TraceKind::MessageDecoded,
					session,
					a: None,
					b: None,
					a_label: None,
					a_profile: None,
					transport: None,
					session_id: None,
					codec: None,
					captp_version: None,
					provenance: DurableProvenance::Unauthenticated,
					outbound: ev.outbound != 0,
					op: view(ev.verb, ev.verb_len),
					len,
					bytes_b64,
					summary,
					digest: Some(hex(&ev.digest)),
					meta: None,
				}
			}
			k if k == TRACE_SESSION_CLOSE => TraceEvent {
				sim_t_ns,
				kind: TraceKind::SessionClosed,
				session,
				a: None,
				b: None,
				a_label: None,
				a_profile: None,
				transport: None,
				session_id: None,
				codec: None,
				captp_version: None,
				provenance: DurableProvenance::Unauthenticated,
				outbound: false,
				op: None,
				len: None,
				bytes_b64: None,
				summary: None,
				digest: None,
				meta: None,
			},
			_ => return None,
		};
		let host = state.hosts.iter().find(|host| host.cookie == cookie)?;
		Some((Rc::clone(&host.context), host.diagnostic_id, sink, record))
	}) else {
		return;
	};
	emit_record(&context, diagnostic_id, sink, record);
}

/// Install the sink (replacing any prior one), start the clock, and register
/// the native tap on every live Host on this thread (a Host minted later
/// registers itself). Returns an uninstall that also clears the native tap.
/// `self_label`, when given, is what the producing application would like its
/// own endpoint CALLED — a display name beside the identity, never instead of
/// it: the `a` endpoint stays the host's own key designator, which is what a
/// partner names it by and so the only name two producers can agree on.
pub fn enable_trace(sink: TraceSink, self_label: Option<&str>) -> impl FnOnce() {
	let (generation, hosts) = STATE.with(|state| {
		let mut state = state.borrow_mut();
		state.generation = state
			.generation
			.checked_add(1)
			.expect("trace installation generation exhausted");
		state.sink = Some(Rc::from(sink));
		state.self_label = self_label.map(str::to_string);
		state.t0 = Instant::now();
		let hosts = state.hosts.iter().map(|h| (h.raw, h.cookie)).collect::<Vec<_>>();
		(state.generation, hosts)
	});
	for (raw, cookie) in hosts {
		unsafe { ffi::pancake_host_set_trace(raw, Some(on_native_event), cookie as *mut c_void) };
	}
	move || {
		let hosts = STATE.with(|state| {
			let mut state = state.borrow_mut();
			if state.generation != generation {
				return None;
			}
			state.sink = None;
			Some(state.hosts.iter().map(|h| h.raw).collect::<Vec<_>>())
		});
		let Some(hosts) = hosts else {
			return;
		};
		for raw in hosts {
			unsafe { ffi::pancake_host_set_trace(raw, None, std::ptr::null_mut()) };
		}
	}
}

/// Binding-internal: a Host reports its raw pointer and its own key
/// designator at construction so an installed trace covers it, and a trace
/// installed later finds it.
pub(crate) fn attach_host(
	raw: *mut ffi::PancakeHost,
	designator: String,
	context: Rc<crate::ContextInner>,
	diagnostic_id: u64,
) {
	let install = STATE.with(|state| {
		let mut state = state.borrow_mut();
		let cookie = state.next_cookie;
		state.next_cookie += 1;
		state.hosts.push(TracedHost {
			raw,
			cookie,
			designator,
			context,
			diagnostic_id,
		});
		state.sink.is_some().then_some(cookie)
	});
	if let Some(cookie) = install {
		unsafe { ffi::pancake_host_set_trace(raw, Some(on_native_event), cookie as *mut c_void) };
	}
}

/// Binding-internal: a released Host leaves the registry. The core dropped
/// its own sink row with the host, so no native call is needed.
pub(crate) fn detach_host(raw: *mut ffi::PancakeHost) {
	STATE.with(|state| {
		state.borrow_mut().hosts.retain(|h| h.raw != raw);
	});
}
