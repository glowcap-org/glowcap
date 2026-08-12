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
use crate::uri::{Locator, OwnedLocator};
use crate::{sys, Error, Result};

/// A resolved dial from `pancake_host_plan_dial`: language sum over the C
/// shape flag (mirrors Zig `DialPlan`). Views are decoded into owned strings
/// before the input buffers die. Crate-visible so the loop route
/// ([`crate::driver_loop`]) reads the same plan the byte-fed dial does.
pub(crate) enum DialPlan {
	HostPort {
		host: String,
		port: u16,
	},
	#[cfg_attr(not(feature = "iroh"), allow(dead_code))]
	PeerId {
		addresses: String,
		reach_kind: u32,
		reach_value: u32,
	},
	/// A signaling-mediated transport (webrtc) — no dialable address; the
	/// channel comes up through an offer/answer/ICE exchange before the keyed
	/// handshake. Cannot be opened from a bare locator; handoff-redeem only.
	Signaling,
	/// A rendezvous-bridged transport (keyed-relay) — no dialable address; the
	/// peer holds an inbound socket at a relay under its key designator, and
	/// the dialer opens the relay rendezvous leg its host is configured for
	/// (ADR-0088).
	Rendezvous,
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
pub(crate) fn plan_dial(
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
	if plan.shape == sys::DIAL_SHAPE_RENDEZVOUS {
		return Ok(DialPlan::Rendezvous);
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

async fn configure_loop_provider(
	lp: &Rc<crate::driver_loop::LoopShared>,
	plan: &DialPlan,
	_locator: &Locator,
) -> Result<()> {
	match plan {
		DialPlan::HostPort { .. } => {
			#[cfg(feature = "tcp")]
			crate::tcp::ensure_loop_provider(lp)?;
			#[cfg(not(feature = "tcp"))]
			return Err(Error::with_detail(
				sys::ERR_INVALID_ARGUMENT,
				"host-port transport support requires the tcp archive".to_string(),
			));
			Ok(())
		}
		#[cfg(feature = "iroh")]
		DialPlan::PeerId {
			reach_kind,
			reach_value,
			..
		} => {
			let host = lp.wrapper_host()?;
			crate::iroh::ensure_loop_provider(
				&host,
				lp,
				crate::iroh::IrohConfig::new(crate::iroh::reachability_from_plan(
					*reach_kind,
					*reach_value,
				)),
			)
			.await?;
			Ok(())
		}
		#[cfg(feature = "relay")]
		DialPlan::Rendezvous => {
			let route = crate::relay_route::from_locator(_locator)?.ok_or_else(|| {
				Error::with_detail(
					sys::ERR_INVALID_ARGUMENT,
					"native relay provider requires a rendezvous-relay locator hint".to_string(),
				)
			})?;
			crate::relay::ensure_loop_provider(lp, route)
		}
		_ => Err(Error::with_detail(
			sys::ERR_INVALID_ARGUMENT,
			"the native loop has no provider for this dial shape".to_string(),
		)),
	}
}

async fn dial_via_loop(plan: DialPlan, locator: &Locator, handshake_ms: u32) -> Result<Session> {
	let lp = crate::driver_loop::LoopShared::open(
		handshake_ms,
		crate::abi_constants::HANDSHAKE_TIMEOUT_MS as u32,
	)?;
	let opened = async {
		configure_loop_provider(&lp, &plan, locator).await?;
		lp.start()?;
		let session = lp.dial_locator(locator).await?;
		crate::driver_loop::loop_session(&lp, session, true)
	}
	.await;
	if opened.is_err() {
		lp.close();
	}
	opened
}

async fn dial_shared_loop(
	lp: Rc<crate::driver_loop::LoopShared>,
	plan: DialPlan,
	locator: &Locator,
) -> Result<Session> {
	configure_loop_provider(&lp, &plan, locator).await?;
	let session = lp.dial_locator(locator).await?;
	crate::driver_loop::loop_session(&lp, session, false)
}

/// The one dial path for [`connect`] and handoff redeem alike: no dispatch, no
/// grammar, no posture — the core resolves all of that in `pancake_host_plan_dial`,
/// and this opens the byte channel the plan names. Every dial through here
/// carries `handshake_timeout`: a peer that accepts the connection and never
/// finishes the OCapN handshake costs one dial, not the caller.
///
/// The driver archive (ADR-0112) is the public dial route for registered
/// provider packages: a bare bounded dial mints one loop per connection, and a
/// dial on a loop-owned Host stages through that existing loop.
/// An externally supplied channel (currently keyed-relay) stays on the
/// byte-fed adapter. A redeem reaches that adapter only when its Host already
/// owns byte-fed sessions; a loop-owned Host redeems inside its own steps.
pub(crate) async fn dial_parsed_locator(
	locator: &Locator,
	host: Option<Host>,
	redeem: bool,
	reachability: Option<Reachability>,
	handshake_timeout: Option<Duration>,
) -> Result<Session> {
	let transport = locator.transport.as_str();
	let designator = locator.designator.as_str();
	let direct_addresses_hint = locator
		.string_hint(crate::abi_constants::HINT_DIRECT_ADDRESSES)?
		.unwrap_or("");
	let (policy, value): (u32, u32) = if redeem {
		(sys::DIAL_POSTURE_REDEEM, 0)
	} else if let Some(r) = reachability {
		(sys::DIAL_POSTURE_EXPLICIT, r as u32)
	} else {
		(sys::DIAL_POSTURE_EXPLICIT_NONE, 0)
	};
	let plan = plan_dial(transport, designator, direct_addresses_hint, policy, value)?;
	#[cfg(any(feature = "relay", feature = "rendezvous"))]
	let relay_route = crate::relay_route::from_locator(locator)?;
	if !redeem {
		let driver_plan = match &plan {
			DialPlan::HostPort { .. } => true,
			#[cfg(feature = "iroh")]
			DialPlan::PeerId { .. } => true,
			#[cfg(feature = "relay")]
			DialPlan::Rendezvous => relay_route.is_some(),
			_ => false,
		};
		let bounded_ms = handshake_timeout
			.filter(|budget| !budget.is_zero())
			.map(|budget| u32::try_from(budget.as_millis()).unwrap_or(u32::MAX).max(1));
		if driver_plan {
			if let Some(handshake_ms) = bounded_ms {
				if let Some(shared_host) = &host {
					let shared = shared_host.shared();
					let lp = shared.ensure_driver_loop(
						handshake_ms,
						crate::abi_constants::HANDSHAKE_TIMEOUT_MS as u32,
					)?;
					return dial_shared_loop(lp, plan, locator).await;
				}
				return dial_via_loop(plan, locator, handshake_ms).await;
			}
		}
	}
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
				// A caller-supplied byte channel: this layer did not open it and
				// so has nothing to say about its far end. The iroh path, which
				// did open its own, testifies there.
				None,
			)
			.await
		}
		DialPlan::Signaling => Err(Error::with_detail(
			sys::ERR_INVALID_ARGUMENT,
			"webrtc signaling dial requires a signaling-aware adapter; a bare locator cannot open it"
				.to_string(),
		)),
		DialPlan::Rendezvous => {
			// The relay mapping is deployment configuration of the dialing
			// host, exactly like the redeem reachability posture beside it.
			#[cfg(feature = "rendezvous")]
			{
				let url = match relay_route {
					Some(route) => crate::relay_route::dial_url(route, designator)?,
					None => shared.rendezvous_url_of(designator).ok_or_else(|| {
						Error::with_detail(
							sys::ERR_INVALID_ARGUMENT,
							"relay dial: locator has no rendezvous-relay hint and the Host has no rendezvous mapping"
								.to_string(),
						)
					})?,
				};
				let stream = crate::ws_stream::connect_websocket(&url).await?;
				Session::establish_dialed_locator(
					shared,
					transport,
					designator,
					stream,
					handshake_timeout,
					// Through a relay the byte channel's far end is the relay,
					// not the partner, and this layer proved neither.
					None,
				)
				.await
			}
			#[cfg(not(feature = "rendezvous"))]
			{
				Err(Error::with_detail(
					sys::ERR_INVALID_ARGUMENT,
					"this build has no rendezvous WebSocket dial; rebuild with the rendezvous feature"
						.to_string(),
				))
			}
		}
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
pub(crate) async fn dial_exporter(locator: &Locator, host: Rc<HostShared>) -> Result<Session> {
	dial_parsed_locator(
		locator,
		Some(Host::from_shared(host)),
		true,
		None,
		Some(HANDSHAKE_TIMEOUT),
	)
	.await
}

/// Ticket-only DIAL arm: clone the complete locator, dial, and report.
pub(crate) async fn run_dial_ticket(host: &Rc<HostShared>, ticket: u64) -> Result<()> {
	use crate::host::{check_host, try_spawn_local};
	use crate::sys::host as ffi;

	let mut opened: Option<Session> = None;
	let result: Result<()> = async {
		let mut hints = vec![unsafe { core::mem::zeroed::<sys::PancakeLocatorHintView>() }; 8];
		let mut view = unsafe { core::mem::zeroed::<sys::PancakeLocatorView>() };
		let mut hint_count = 0usize;
		loop {
			let rc = unsafe {
				ffi::pancake_host_pending_dial(
					host.raw(),
					ticket,
					hints.as_mut_ptr(),
					hints.len(),
					&mut view,
					&mut hint_count,
				)
			};
			if rc != sys::ERR_BUFFER_TOO_SMALL {
				check_host(rc)?;
				break;
			}
			hints.resize(hint_count, unsafe { core::mem::zeroed() });
		}
		let locator = OwnedLocator::clone_view(&view)?.value()?;
		// Boxed to break the async recursion cycle: the dial's establish
		// runs its own reentrant drain (its start-session FLUSH).
		let session = Box::pin(dial_exporter(&locator, Rc::clone(host))).await?;
		host.guard_open()?;
		let raw_session = session.raw_session();
		opened = Some(session);
		check_host(unsafe { ffi::pancake_host_dialed(host.raw(), ticket, raw_session) })?;
		let session = opened.take().expect("reported session remains owned");
		let serving = session.serve();
		let _ = try_spawn_local(async move {
			serving.await;
			drop(session);
		});
		Ok(())
	}
	.await;
	match result {
		Ok(()) => Ok(()),
		Err(error) => {
			if let Some(session) = opened.take() {
				session.close();
			}
			if host.closing() {
				return Ok(());
			}
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
	dial_parsed_locator(&loc, host, false, reachability, handshake_timeout).await
}
