//! The dial executor (binding spine Pass 3c): one path that turns a parsed
//! locator into an open, handshaken [`Session`], shared by [`connect`] and
//! handoff-redeem alike.
//!
//! Every dial decision — the host:port grammar, the direct-addresses hint rule,
//! the peer-id reachability posture, the scheme dispatch, and the typed errors —
//! is resolved once in the core by `pancake_host_plan_dial`, which hands back a
//! `PancakeDialPlan`. This module holds no dial business logic: it marshals the
//! posture, reads the plan into a language sum, and performs the one thing the
//! core cannot — the async byte-channel open (`TcpStream::connect`, or the iroh
//! companion). Adding a transport is a core change, not an edit here. Session
//! owns mint/handshake (`establish_dialed_locator` / `establish_accepted`); this
//! module owns plan + channel open + the public [`connect`] dialer.

use std::rc::Rc;
use std::time::Duration;

use tokio::net::TcpStream;

use crate::host::{check_host, Host, HostShared};
use crate::session::{io_err, Session, HANDSHAKE_TIMEOUT};
use crate::sys::host as ffi;
use crate::{sys, Error, Result};

/// A resolved dial from `pancake_host_plan_dial`: language sum over the C
/// shape flag (mirrors Zig `DialPlan`). Views are decoded into owned strings
/// before the input buffers die.
enum DialPlan {
	HostPort {
		host: String,
		port: u16,
	},
	PeerId {
		addresses: String,
		reach_kind: u32,
		reach_value: u32,
	},
	/// A signaling-mediated transport (webrtc) — no dialable address; the
	/// channel comes up through an offer/answer/ICE exchange before the keyed
	/// handshake. Cannot be opened from a bare locator; handoff-redeem only.
	Signaling,
}

/// Host-owned pending-dial views (not input-buffer aliases).
fn view_string(ptr: *const u8, len: usize) -> String {
	if ptr.is_null() || len == 0 {
		String::new()
	} else {
		String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(ptr, len) }).into_owned()
	}
}

/// Decode a plan view that aliases one of the UTF-8 input buffers (one OS
/// connect string). A non-alias view is a core contract break.
fn decode_plan_view(sources: &[&[u8]], ptr: *const u8, len: usize) -> Result<String> {
	if ptr.is_null() || len == 0 {
		return Ok(String::new());
	}
	let p = ptr as usize;
	for src in sources {
		let base = src.as_ptr() as usize;
		if p >= base && p + len <= base + src.len() {
			let off = p - base;
			return Ok(String::from_utf8_lossy(&src[off..off + len]).into_owned());
		}
	}
	Err(Error::with_detail(
		sys::ERR_INVALID_ARGUMENT,
		"dial plan view does not alias input buffers".to_string(),
	))
}

/// Resolve a dial in the core: the host:port grammar, the hint rule, the
/// peer-id posture, and the error cases all decided by `pancake_host_plan_dial`.
/// Plan views alias the input UTF-8 buffers; decode those subslices only.
fn plan_dial(
	transport: &str,
	designator: &str,
	direct_addresses_hint: &str,
	posture_policy: u32,
	posture_value: u32,
) -> Result<DialPlan> {
	let mut plan: ffi::PancakeDialPlan = unsafe { core::mem::zeroed() };
	check_host(unsafe {
		ffi::pancake_host_plan_dial(
			transport.as_ptr(),
			transport.len(),
			designator.as_ptr(),
			designator.len(),
			direct_addresses_hint.as_ptr(),
			direct_addresses_hint.len(),
			posture_policy,
			posture_value,
			&mut plan,
		)
	})?;
	let sources: [&[u8]; 2] = [designator.as_bytes(), direct_addresses_hint.as_bytes()];
	if plan.shape == sys::DIAL_SHAPE_PEER_ID {
		return Ok(DialPlan::PeerId {
			addresses: decode_plan_view(&sources, plan.addresses, plan.addresses_len)?,
			reach_kind: plan.reach_kind,
			reach_value: plan.reach_value,
		});
	}
	if plan.shape == sys::DIAL_SHAPE_HOST_PORT {
		return Ok(DialPlan::HostPort {
			host: decode_plan_view(&sources, plan.host, plan.host_len)?,
			port: plan.port,
		});
	}
	if plan.shape == sys::DIAL_SHAPE_SIGNALING {
		return Ok(DialPlan::Signaling);
	}
	Err(Error::with_detail(
		sys::ERR_INVALID_ARGUMENT,
		format!("unknown dial shape {}", plan.shape),
	))
}

/// How an iroh endpoint becomes reachable — the mandatory posture an iroh dial or
/// listen chooses, in the open. There is no default: a pancake peer never turns on
/// relays or a discovery service as a hidden implementation detail, so the caller
/// always names one. A `tcp` dial ignores it (pass `None` to [`connect`]).
///
/// - `Direct`: relay-less, lookup-less — dial by id plus explicit address hints
///   (loopback/LAN). The rooms demo's posture: its URIs carry direct-addresses.
/// - `Discovery`: number-0 relays + DNS/pkarr discovery — dialable by id alone
///   over the internet, with hole-punching and NAT traversal.
/// - `DiscoveryNoRelay`: DNS/pkarr discovery without relays.
/// - `LocalDiscovery`: in-process shared address book — resolves by id alone
///   with no relay, DNS, or hints. For tests and same-process embeddings.
#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Reachability {
	Direct = crate::abi_constants::IROH_REACH_DIRECT,
	Discovery = crate::abi_constants::IROH_REACH_DISCOVERY,
	DiscoveryNoRelay = crate::abi_constants::IROH_REACH_DISCOVERY_NO_RELAY,
	LocalDiscovery = crate::abi_constants::IROH_REACH_LOCAL_DISCOVERY,
}

impl Reachability {
	/// The posture a hint-less handoff give redeems under until
	/// [`crate::Host::set_redeem_reachability`] changes it. The compile-time
	/// assert below locks it to the generated ABI default, so the variant here
	/// cannot drift from the value every other binding starts from.
	pub(crate) const REDEEM_DEFAULT: Reachability = Reachability::Discovery;
}
const _: () =
	assert!(Reachability::REDEEM_DEFAULT as u32 == crate::abi_constants::IROH_REACH_REDEEM_DEFAULT);

/// The one dial path for [`connect`] and handoff redeem alike: no dispatch, no
/// grammar, no posture — the core resolves all of that in `pancake_host_plan_dial`,
/// and this opens the byte channel the plan names. Every dial through here
/// carries `handshake_timeout`: a peer that accepts the connection and never
/// finishes the OCapN handshake costs one dial, not the caller.
pub(crate) async fn dial_parsed_locator(
	transport: &str,
	designator: &str,
	direct_addresses_hint: &str,
	host: Option<Host>,
	redeem: bool,
	reachability: Option<Reachability>,
	handshake_timeout: Option<Duration>,
) -> Result<Session> {
	let owns_host = !redeem && host.is_none();
	let dial_host = if redeem {
		host.ok_or_else(|| {
			Error::with_detail(
				sys::ERR_INVALID_ARGUMENT,
				"handoff redeem requires a shared host".to_string(),
			)
		})?
	} else {
		host.unwrap_or_else(Host::new_host)
	};
	let shared = dial_host.shared();
	let (policy, value): (u32, u32) = if redeem {
		(sys::DIAL_POSTURE_REDEEM, 0)
	} else if let Some(r) = reachability {
		(sys::DIAL_POSTURE_EXPLICIT, r as u32)
	} else {
		(sys::DIAL_POSTURE_EXPLICIT_NONE, 0)
	};
	let plan = plan_dial(transport, designator, direct_addresses_hint, policy, value)?;
	let mut session = match plan {
		DialPlan::PeerId {
			addresses,
			reach_kind,
			reach_value,
		} => {
			#[cfg(feature = "iroh")]
			{
				let reachability = match reach_kind {
					sys::DIAL_REACH_DIRECT => Reachability::Direct,
					sys::DIAL_REACH_CONFIGURED => shared.redeem_reachability(),
					_ => match reach_value {
						v if v == Reachability::Direct as u32 => Reachability::Direct,
						v if v == Reachability::Discovery as u32 => Reachability::Discovery,
						v if v == Reachability::DiscoveryNoRelay as u32 => {
							Reachability::DiscoveryNoRelay
						}
						v if v == Reachability::LocalDiscovery as u32 => {
							Reachability::LocalDiscovery
						}
						_ => unreachable!("EXPLICIT reach_value is a Reachability discriminant"),
					},
				};
				Session::connect_iroh_with_host(
					designator,
					&addresses,
					reachability,
					dial_host,
					handshake_timeout,
				)
				.await
			}
			#[cfg(not(feature = "iroh"))]
			{
				let _ = (addresses, reach_kind, reach_value);
				Err(Error::with_detail(
					sys::ERR_INVALID_ARGUMENT,
					"this build has no iroh transport; rebuild with the iroh feature".to_string(),
				))
			}
		}
		DialPlan::HostPort { host, port } => {
			let stream = TcpStream::connect((host.as_str(), port))
				.await
				.map_err(io_err)?;
			Session::establish_dialed_locator(
				shared,
				transport,
				designator,
				stream,
				handshake_timeout,
			)
			.await
		}
		DialPlan::Signaling => Err(Error::with_detail(
			sys::ERR_INVALID_ARGUMENT,
			"webrtc signaling dial requires a signaling-aware adapter; a bare locator cannot open it"
				.to_string(),
		)),
	}?;
	session.set_owns_host(owns_host);
	Ok(session)
}

/// Dial an exporter a DIAL action names, keyed with the host's retained
/// identity, and bind the result to that same node so the redeemed capability
/// and any further handoff it triggers share one identity and connection
/// table. The action carries the locator's parsed pieces; this path calls
/// `pancake_host_plan_dial` and opens the channel the plan names. An `iroh`
/// give with direct-address hints dials them with no discovery service
/// (`Direct`); a bare node id resolves by id under the host's configured
/// redeem posture (default `Discovery`; a relay-policy node lowers it), so
/// one give shape covers an offline direct dial and an internet dial-by-id
/// alike. An exporter that never finishes the handshake breaks the redeem on
/// [`HANDSHAKE_TIMEOUT`] rather than stalling the drain. Binding-internal: the
/// host's action drain calls this to redeem a give.
pub(crate) async fn dial_exporter(
	transport: &str,
	designator: &str,
	direct_addresses_hint: &str,
	host: Rc<HostShared>,
) -> Result<Session> {
	dial_parsed_locator(
		transport,
		designator,
		direct_addresses_hint,
		Some(Host::from_shared(host)),
		true,
		None,
		Some(HANDSHAKE_TIMEOUT),
	)
	.await
}

/// Ticket-only DIAL arm: borrow parsed parts (no URI re-parse), dial, report.
pub(crate) async fn run_dial_ticket(host: &Rc<HostShared>, ticket: u64) -> Result<()> {
	use crate::host::{check_host, try_spawn_local};
	use crate::sys::host as ffi;

	let mut view: ffi::PancakePendingDial = unsafe { core::mem::zeroed() };
	let result = async {
		check_host(unsafe { ffi::pancake_host_pending_dial(host.raw(), ticket, &mut view) })?;
		let transport = view_string(view.transport, view.transport_len);
		let designator = view_string(view.designator, view.designator_len);
		let hint = view_string(view.hint, view.hint_len);
		// Boxed to break the async recursion cycle: the dial's establish
		// runs its own reentrant drain (its start-session FLUSH).
		let session = Box::pin(dial_exporter(
			&transport,
			&designator,
			&hint,
			Rc::clone(host),
		))
		.await?;
		let raw_conn = session.raw_conn();
		let serving = session.serve();
		try_spawn_local(async move {
			serving.await;
			drop(session);
		});
		check_host(unsafe { ffi::pancake_host_dialed(host.raw(), ticket, raw_conn) })
	}
	.await;
	match result {
		Ok(()) => Ok(()),
		Err(error) => {
			let reason = error.to_string();
			check_host(unsafe {
				ffi::pancake_host_dial_failed(host.raw(), ticket, reason.as_ptr(), reason.len())
			})
		}
	}
}

/// Dial a partner from its `ocapn://` locator — the one dialer, transport-neutral.
/// A `tcp` locator (including one built with [`crate::tcp_locator`]) ignores
/// `reachability`, so pass `None`; an `iroh` locator requires it (the posture is
/// never guessed). `host` shares one identity across a server and dialed siblings
/// (gifter handoff); only `tcp` / `keyed-tcp` thread it. The signature is the same whether or not the iroh transport is
/// compiled in, so a call site never changes when the feature is turned on —
/// without it, an `iroh` locator fails with a rebuild hint rather than dialing,
/// and a tcp-only build links no iroh companion library.
///
/// The OCapN handshake is bounded at [`HANDSHAKE_TIMEOUT`] once the byte
/// channel is open, so a peer that accepts the connection and then says
/// nothing fails with [`ErrorKind::TimedOut`](crate::ErrorKind::TimedOut)
/// instead of parking the caller. [`connect_with_timeout`] chooses a different
/// budget, or none at all.
pub async fn connect(
	uri: &str,
	reachability: Option<Reachability>,
	host: Option<Host>,
) -> Result<Session> {
	connect_with_timeout(uri, reachability, host, Some(HANDSHAKE_TIMEOUT)).await
}

/// [`connect`] under a caller-chosen handshake budget — how a dialer with its
/// own deadline, or one that means to wait indefinitely, says so.
///
/// `handshake_timeout` bounds the OCapN handshake once the byte channel is
/// open. `None` waits unbounded, and so does a zero budget: zero is how the C
/// ABI and the sibling bindings spell "no bound", so a configured millisecond
/// count threaded through here means what it means everywhere else. This
/// project's rule for CapTP waits treats an unbounded one as a hang rather than
/// a slow success, so ask for it only with a deadline of your own around the
/// call. It does not cover opening the channel:
/// a TCP connect keeps the OS's own timeout, and an iroh dial-by-id keeps its
/// discovery retry budget (ADR-0082), both spent before the handshake starts.
pub async fn connect_with_timeout(
	uri: &str,
	reachability: Option<Reachability>,
	host: Option<Host>,
	handshake_timeout: Option<Duration>,
) -> Result<Session> {
	let loc = crate::uri::parse_locator(uri)?;
	let hint = loc
		.hints
		.get(crate::abi_constants::HINT_DIRECT_ADDRESSES)
		.map(String::as_str)
		.unwrap_or("");
	dial_parsed_locator(
		&loc.transport,
		&loc.designator,
		hint,
		host,
		false,
		reachability,
		handshake_timeout,
	)
	.await
}
