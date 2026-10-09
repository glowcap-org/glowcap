//! The live timeline producer: a veneer over the native tap. The core is the
//! one owner of the facts — `glowcap_host_set_trace` reports every session's
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

use crate::execution::Instant;
use std::cell::RefCell;
use std::ffi::c_void;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::rc::Rc;

use crate::abi_constants_gen::{
	BINDING_TRACE_PAYLOAD_CAP_BYTES, TRACE_MESSAGE, TRACE_SESSION_CLOSE, TRACE_SESSION_OPEN,
};
use crate::session::DurableProvenance;
use crate::sys::host as ffi;

mod labels;
mod projection;
pub use labels::set_trace_label;
use projection::{base64, captp_version, codec, hex, view};

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
	/// host's own OCapN Designator, the name a partner knows it by, so
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
	/// `"glowcap"` here. A statement about the producer, beside the designator
	/// it calls itself by and the label it would like to be shown under, and on
	/// the same footing as the `provenance` verdict below: a conclusion the
	/// producer states rather than a raw wire fact.
	///
	/// It is stated because this schema is not glowcap's alone — the Goblins
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
	/// (`"1.0"` / `"glowcap-next"`). Reported beside the codec because the
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
/// true length above it).
const PAYLOAD_CAP: usize = BINDING_TRACE_PAYLOAD_CAP_BYTES;

/// What this producer answers when a record asks what it runs. A constant and
/// not an option: the host behind this binding is a glowcap host, and letting
/// an application name itself something else would put a claim on the wire
/// that nothing here could stand behind.
///
/// Each of the four bindings states this word itself, because it is a claim
/// about the binding tier rather than a fact the core or the C ABI carries, so
/// there is no declaration to generate it from. `zig build source-check`
/// (`checkTraceViewerVocabulary`) holds all four against each other, against
/// the viewer that reads them, and against the Goblins conformance publisher,
/// which states a different word and must keep stating it.
const SELF_PROFILE: &str = "glowcap";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TraceKind {
	SessionOpened,
	MessageDecoded,
	SessionClosed,
	/// An application annotation about the session (`annotate_session`).
	SessionMeta,
}

/// An application's claim about a session — see `annotate_session`. A
/// `None` label withdraws the claim a viewer was showing.
#[derive(Debug, Clone)]
pub struct SessionMeta {
	pub label: Option<String>,
}

pub type TraceSink = Box<dyn Fn(&TraceEvent)>;

type TraceCallback = Rc<dyn Fn(&TraceEvent)>;

fn emit_record(context: &crate::ContextInner, diagnostic_id: u64, sink: TraceCallback, record: TraceEvent) {
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
/// identity, and `None` withdraws it: a member leaving the room the label
/// named them in is one visible change in the picture rather than a name
/// frozen at whatever was said first. No sink installed, or a host the
/// trace never attached: silently nothing, like every other trace emit.
pub fn annotate_session(session: &crate::Session, label: Option<&str>) {
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
	let code = unsafe { ffi::glowcap_host_session_trace_id(session_raw, &mut id) };
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
				label: label.map(str::to_owned),
			}),
		},
	);
}

struct TracedHost {
	raw: *mut ffi::GlowcapHost,
	/// The small integer passed as the callback ctx so a record can carry
	/// which host it came from (the Names rule: a bare host-scoped id needs
	/// its namespace named, or two hosts in one process collide).
	cookie: usize,
	/// The host's own key designator, the name a partner knows it by.
	designator: String,
	context: Rc<crate::ContextInner>,
	diagnostic_id: u64,
}

struct TraceState {
	sink: Option<TraceCallback>,
	/// Identity of the current installation. Pointer identity lets an older
	/// uninstall closure recognize a replacement without an exhaustible counter.
	installation: Option<Rc<()>>,
	/// The display label the application chose for its own endpoint, or None.
	self_label: Option<String>,
	t0: Instant,
	hosts: Vec<TracedHost>,
	next_cookie: usize,
}

impl Drop for TraceState {
	fn drop(&mut self) {
		// Hosts held by another TLS owner may outlive this registry. Disarm
		// their native callbacks before the sink and registry context retire.
		for host in &self.hosts {
			unsafe { ffi::glowcap_host_set_trace(host.raw, None, std::ptr::null_mut()) };
		}
	}
}

thread_local! {
	static STATE: RefCell<TraceState> = RefCell::new(TraceState {
		sink: None,
		installation: None,
		self_label: None,
		t0: Instant::now(),
		hosts: Vec::new(),
		next_cookie: 1,
	});
}

type ProjectedTrace = (Rc<crate::ContextInner>, u64, TraceCallback, TraceEvent);

fn project_native_event(cookie: usize, ev: &ffi::GlowcapTraceEvent) -> crate::Result<Option<ProjectedTrace>> {
	STATE.with(|state| {
		let state = state.try_borrow().map_err(|_| {
			crate::Error::with_detail(
				crate::sys::ERR_INTERNAL,
				"trace callback re-entered its binding state".into(),
			)
		})?;
		let Some(sink) = state.sink.clone() else {
			return Ok(None);
		};
		let host = state.hosts.iter().find(|host| host.cookie == cookie).ok_or_else(|| {
			crate::Error::with_detail(
				crate::sys::ERR_INTERNAL,
				format!("glowcap ABI invoked trace callback for unknown host cookie {cookie}"),
			)
		})?;
		let sim_t_ns = state.t0.elapsed().as_nanos() as u64;
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
				b: Some(view(ev.designator, ev.designator_len, "designator")?.unwrap_or_else(|| String::from("peer"))),
				transport: view(ev.transport, ev.transport_len, "transport")?,
				session_id: view(ev.session_id, ev.session_id_len, "session id")?,
				codec: Some(codec(ev.codec)?),
				captp_version: Some(captp_version(ev.captp_version)?),
				provenance: DurableProvenance::from_abi(ev.provenance)?,
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
				} else if ev.frame_len > total_len {
					return Err(crate::Error::with_detail(
						crate::sys::ERR_INTERNAL,
						"glowcap ABI returned a trace frame prefix longer than its total length".into(),
					));
				} else if ev.frame_len > 0 {
					if ev.frame.is_null() {
						return Err(crate::Error::with_detail(
							crate::sys::ERR_INTERNAL,
							"glowcap ABI returned a null trace frame with nonzero length".into(),
						));
					}
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
					outbound: match ev.outbound {
						0 => false,
						1 => true,
						other => {
							return Err(crate::Error::with_detail(
								crate::sys::ERR_INTERNAL,
								format!("glowcap ABI returned unknown trace direction {other}"),
							));
						}
					},
					op: view(ev.verb, ev.verb_len, "verb")?,
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
			other => {
				return Err(crate::Error::with_detail(
					crate::sys::ERR_INTERNAL,
					format!("glowcap ABI returned unknown trace event kind {other}"),
				));
			}
		};
		Ok(Some((Rc::clone(&host.context), host.diagnostic_id, sink, record)))
	})
}

fn report_callback_failure(cookie: usize, operation: &str, error: crate::Error) {
	let owner = STATE.with(|state| {
		let state = state.try_borrow().ok()?;
		let host = state.hosts.iter().find(|host| host.cookie == cookie)?;
		Some((Rc::clone(&host.context), host.diagnostic_id))
	});
	if let Some((context, diagnostic_id)) = owner {
		context.report_failure(
			crate::FailureLayer::Binding,
			crate::FailureScope::Host,
			diagnostic_id,
			0,
			operation,
			&error,
		);
	} else {
		crate::record_runtime_failure(crate::FailureLayer::Binding, operation, error);
	}
}

unsafe extern "C" fn on_native_event(ctx: *mut c_void, event: *const ffi::GlowcapTraceEvent) {
	let cookie = ctx as usize;
	let projected = catch_unwind(AssertUnwindSafe(|| {
		if event.is_null() {
			return Err(crate::Error::with_detail(
				crate::sys::ERR_INTERNAL,
				"glowcap ABI invoked trace callback with a null event".into(),
			));
		}
		project_native_event(cookie, unsafe { &*event })
	}));
	match projected {
		Ok(Ok(Some((context, diagnostic_id, sink, record)))) => emit_record(&context, diagnostic_id, sink, record),
		Ok(Ok(None)) => {}
		Ok(Err(error)) => report_callback_failure(cookie, "trace.decode", error),
		Err(payload) => report_callback_failure(
			cookie,
			"trace.callback",
			crate::Error::with_detail(crate::sys::ERR_INTERNAL, crate::panic_message(payload.as_ref())),
		),
	}
}

/// Install the sink (replacing any prior one), start the clock, and register
/// the native tap on every live Host on this thread (a Host minted later
/// registers itself). Returns an uninstall that also clears the native tap.
/// `self_label`, when given, is what the producing application would like its
/// own endpoint CALLED — a display name beside the identity, never instead of
/// it: the `a` endpoint stays the host's own key designator, the name a
/// partner knows it by and the only one two producers can agree on.
pub fn enable_trace(sink: TraceSink, self_label: Option<&str>) -> impl FnOnce() + use<> {
	let installation = Rc::new(());
	let hosts = STATE.with(|state| {
		let mut state = state.borrow_mut();
		state.installation = Some(Rc::clone(&installation));
		state.sink = Some(Rc::from(sink));
		state.self_label = self_label.map(str::to_string);
		state.t0 = Instant::now();
		state.hosts.iter().map(|h| (h.raw, h.cookie)).collect::<Vec<_>>()
	});
	for (raw, cookie) in hosts {
		unsafe { ffi::glowcap_host_set_trace(raw, Some(on_native_event), cookie as *mut c_void) };
	}
	move || {
		let hosts = STATE.with(|state| {
			let mut state = state.borrow_mut();
			if !state
				.installation
				.as_ref()
				.is_some_and(|current| Rc::ptr_eq(current, &installation))
			{
				return None;
			}
			state.installation = None;
			state.sink = None;
			Some(state.hosts.iter().map(|h| h.raw).collect::<Vec<_>>())
		});
		let Some(hosts) = hosts else {
			return;
		};
		for raw in hosts {
			unsafe { ffi::glowcap_host_set_trace(raw, None, std::ptr::null_mut()) };
		}
	}
}

fn allocate_trace_cookie(state: &mut TraceState) -> usize {
	loop {
		let cookie = state.next_cookie;
		state.next_cookie = state.next_cookie.wrapping_add(1);
		if state.next_cookie == 0 {
			state.next_cookie = 1;
		}
		if cookie != 0 && state.hosts.iter().all(|host| host.cookie != cookie) {
			return cookie;
		}
	}
}

/// Binding-internal: a Host reports its raw pointer and its own key
/// designator at construction so an installed trace covers it, and a trace
/// installed later finds it.
pub(crate) fn attach_host(
	raw: *mut ffi::GlowcapHost,
	designator: String,
	context: Rc<crate::ContextInner>,
	diagnostic_id: u64,
) {
	let install = STATE.with(|state| {
		let mut state = state.borrow_mut();
		let cookie = allocate_trace_cookie(&mut state);
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
		unsafe { ffi::glowcap_host_set_trace(raw, Some(on_native_event), cookie as *mut c_void) };
	}
}

/// Binding-internal: a released Host leaves the registry. The core dropped
/// its own sink row with the host, so no native call is needed.
pub(crate) fn detach_host(raw: *mut ffi::GlowcapHost) {
	// A late TLS owner can release Host after TraceState::drop has removed
	// every native callback. No registry row remains to retire in that case.
	let _ = STATE.try_with(|state| {
		state.borrow_mut().hosts.retain(|h| h.raw != raw);
	});
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn an_old_uninstall_cannot_disable_its_replacement() {
		let uninstall_old = enable_trace(Box::new(|_| {}), None);
		let uninstall_current = enable_trace(Box::new(|_| {}), None);
		uninstall_old();
		STATE.with(|state| assert!(state.borrow().sink.is_some()));
		uninstall_current();
		STATE.with(|state| assert!(state.borrow().sink.is_none()));
	}

	#[test]
	fn trace_cookies_wrap_without_using_zero() {
		let mut state = TraceState {
			sink: None,
			installation: None,
			self_label: None,
			t0: Instant::now(),
			hosts: Vec::new(),
			next_cookie: usize::MAX,
		};
		assert_eq!(allocate_trace_cookie(&mut state), usize::MAX);
		assert_eq!(allocate_trace_cookie(&mut state), 1);
	}

	#[test]
	fn malformed_native_trace_is_contained_and_reported() {
		let context = Rc::new(crate::ContextInner::new().unwrap());
		let cookie = STATE.with(|state| {
			let mut state = state.borrow_mut();
			let cookie = allocate_trace_cookie(&mut state);
			state.sink = Some(Rc::new(|_| {}));
			state.hosts.push(TracedHost {
				raw: std::ptr::null_mut(),
				cookie,
				designator: "test".into(),
				context: Rc::clone(&context),
				diagnostic_id: 17,
			});
			cookie
		});
		let mut event: ffi::GlowcapTraceEvent = unsafe { core::mem::zeroed() };
		event.kind = u32::MAX;
		unsafe { on_native_event(cookie as *mut c_void, &event) };
		let failure = context.next_failure().unwrap().expect("decoder failure is retained");
		assert_eq!(failure.operation, "trace.decode");
		assert_eq!(failure.scope, crate::FailureScope::Host);
		assert_eq!(failure.scope_id, 17);
		assert!(failure.primary_message.contains("unknown trace event kind"));
		STATE.with(|state| {
			let mut state = state.borrow_mut();
			state.sink = None;
			state.hosts.retain(|host| host.cookie != cookie);
		});
	}
}
