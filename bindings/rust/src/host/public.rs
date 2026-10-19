//! Public Host construction, identity, limits, and session lookup surface.

use super::*;
use crate::{CaptpVersion, Session};
/// The CapTP Host: one identity, one actor graph, one routing and redeem
/// authority, shared by every session minted against it. Owns `engine.Node`
/// (router half of Goblins mycapn, while Host carries the product role: ADR-0011).
/// The cross-session machinery lives in the Zig core behind `libglowcap_host`
/// (ADR-0022). This is the host-idiom residue over it: the session registry,
/// the vow table, the action drain that performs the I/O the host asks for
/// (dial, flush, settle, entropy), and the iroh redeem posture. Cloning shares
/// the same Host. The FFI host is released when the last clone (and last
/// session) drops.
#[derive(Clone)]
pub struct Host {
	pub(super) shared: Rc<HostShared>,
}

/// Identity authority for a listening Host.
///
/// A seed restores the Host's durable identity without retaining an existing
/// session directory. Supplying a [`Host`] shares both its identity and its
/// live publications, sessions, and handoff router.
#[derive(Clone, Default)]
pub enum ListenerIdentity {
	#[default]
	Fresh,
	Seed([u8; 32]),
	Host(Host),
}

#[cfg(any(
	feature = "tcp",
	feature = "iroh",
	feature = "onion",
	feature = "relay",
	feature = "webrtc"
))]
impl ListenerIdentity {
	pub(crate) fn into_host(self) -> Result<Host> {
		match self {
			Self::Fresh => Host::with_options(HostOptions::default()),
			Self::Seed(seed) => Host::from_seed(seed),
			Self::Host(host) => Ok(host),
		}
	}
}

/// Construction knobs for [`Host`]. Codec, CapTP profile, feature offer, and
/// local-turn budget are mint-time. Each session settles version and codec with
/// its partner, falling back to v1.0/Syrup when needed, and runs only the
/// intersection of the two offered feature sets. Selective session limits stay
/// on [`Host::set_session_limits`] (ADR-0008).
#[derive(Debug, Clone, Copy, Default)]
pub struct HostOptions {
	pub codec: Codec,
	/// The CapTP profile this Host prefers. See
	/// [`CaptpVersion`](crate::CaptpVersion).
	pub captp_version: crate::CaptpVersion,
	/// Optional CapTP features this Host advertises.
	pub features: crate::FeatureSet,
	/// Caps local-turn amplification per session (ADR-0018). `0` applies the
	/// Host's finite default, `u32::MAX` (the C ABI's
	/// `GLOWCAP_LOCAL_TURN_BUDGET_UNBOUNDED`) turns the cap off, and any other
	/// value is the cap.
	pub local_turn_budget: u32,
}

impl HostOptions {
	/// Select one core-authored coherent codec/version pair.
	pub fn with_profile(profile: crate::HostProfile) -> Self {
		Self {
			codec: profile.codec(),
			captp_version: profile.captp_version(),
			..Self::default()
		}
	}

	pub fn with_codec(codec: Codec) -> Self {
		Self {
			codec,
			..Self::default()
		}
	}
}

/// Selective overrides copied into sessions minted after the call. Zero fields
/// preserve the Host's current value. The durable sent-answer budget remains
/// separate from transient outbound flow pressure.
#[derive(Debug, Clone, Copy, Default)]
pub struct SessionLimitOptions {
	pub max_frame_bytes: usize,
	pub queue_cap: usize,
	pub outbound_high_water_bytes: usize,
	pub max_retained_sent_answer_bytes: u32,
}

impl Host {
	/// Close every session this host holds, then release the FFI Host and its
	/// hosted callbacks. Every clone becomes closed. When called by a hosted
	/// behavior, teardown is parked until that callback returns.
	///
	/// Closing a [`Session`](crate::Session) closes that one connection and
	/// nothing else, so this is how an application that shares one host across
	/// several sessions tears the whole thing down. The returned future is the
	/// completion barrier for Host-owned work and FFI state.
	pub async fn close(&self, pending: PendingWork) -> Result<()> {
		crate::finalizer::drain();
		self.shared.close_host(pending)?;
		self.shared.wait_closed().await
	}

	#[cfg(test)]
	pub(crate) fn request_close(&self) {
		let _ = self.shared.close_host(PendingWork::Cancel);
	}

	// Test convenience over the fallible public constructor. Production callers
	// always receive initialization and entropy failures through `Result`.
	#[cfg(test)]
	pub(crate) fn new_host() -> Host {
		Host::with_options(HostOptions::default()).expect("test Host initialization")
	}

	/// A fresh Host whose sessions all negotiate in `codec`: the codec is a
	/// Host property, so every session minted against a shared Host speaks
	/// the same grammar. Pass the Host to
	/// [`RuntimeConfig::adopt_host`](crate::RuntimeConfig::adopt_host),
	/// or, with FFI TCP enabled, to `tcp::listen` through `tcp::ListenOptions`.
	pub fn with_codec(codec: Codec) -> Result<Host> {
		Host::with_options(HostOptions::with_codec(codec))
	}

	/// A fresh Host from [`HostOptions`] (codec + local-turn budget).
	pub fn with_options(options: HostOptions) -> Result<Host> {
		let mut seed = [0u8; 32];
		getrandom::fill(&mut seed).map_err(|error| {
			Error::with_detail(sys::ERR_IO, format!("drawing the Host identity seed failed: {error}"))
		})?;
		Host::from_seed_with_options(seed, options)
	}

	/// A Host whose retained Ed25519 identity is reconstructed from `seed`.
	/// This keeps a keyed-TCP designator stable across a rebind while each
	/// session still receives a fresh signing key (ADR-0028).
	/// Omitted profile options use the generated C ABI defaults.
	pub fn from_seed(seed: [u8; 32]) -> Result<Host> {
		Host::from_seed_with_options(seed, HostOptions::default())
	}

	/// [`Self::from_seed`] with full [`HostOptions`] (codec + local-turn budget).
	pub fn from_seed_with_options(seed: [u8; 32], options: HostOptions) -> Result<Host> {
		Ok(Host {
			shared: HostShared::new(
				seed,
				options.codec,
				options.captp_version,
				options.features,
				options.local_turn_budget,
				None,
			)?,
		})
	}

	/// Apply selective limits to peers minted after this call.
	pub fn set_session_limits(&self, options: SessionLimitOptions) -> Result<()> {
		self.shared.set_session_limits(options)
	}
	/// Set per-ingress queue bounds before any session or eventual send. Byte
	/// limits include message spines and queue rows, and allocate no eager payload.
	pub fn set_ingress_limits(
		&self,
		max_pending_turns: u32,
		max_pending_bytes: u32,
		max_chunk_bytes: u32,
	) -> Result<()> {
		self.shared.guard_handle()?;
		// SAFETY: `self.shared.raw()` is the `GlowcapHost` handle owned by this Host's `HostShared`, released only when
		// the Host closes, and `guard_handle` above proved it non-null; the remaining arguments are integers passed by
		// value.
		check_host(unsafe {
			ffi::glowcap_host_set_ingress_limits(
				self.shared.raw(),
				max_pending_turns,
				max_pending_bytes,
				max_chunk_bytes,
			)
		})
	}

	/// Choose whether far capabilities this Host hands the application release
	/// their Host retain when the last `Ref` clone drops (ADR-0025). On by
	/// default: the partner learns through `op:gc-exports` that the import is
	/// gone. Turn it off only to release every capability explicitly. The
	/// setting lives on the Host archive (ADR-0025) and applies to outcomes
	/// minted after the call, on every session.
	pub fn set_release_on_drop(&self, enabled: bool) -> Result<()> {
		// SAFETY: `self.shared.raw()` is this `HostShared`'s handle from `glowcap_host_new_in`, which the callee
		// refuses as a null host once teardown has cleared it.
		check_host(unsafe { ffi::glowcap_host_set_release_on_drop(self.shared.raw(), u32::from(enabled)) })
	}

	/// Claim every callerless failure retained by this Host's allocation
	/// context. This is the same queue a caller-supplied [`Context`] exposes.
	/// Returned and close-barrier failures are not duplicated here.
	pub fn take_failures(&self) -> Result<Vec<crate::FailureEvent>> {
		let Some(context) = self.shared.retained_context() else {
			return Ok(Vec::new());
		};
		let mut failures = Vec::new();
		while let Some(failure) = context.next_failure()? {
			failures.push(failure);
		}
		Ok(failures)
	}

	/// Retain and select this Host's complete acceptable location. Later
	/// sessions advertise it regardless of their transport. Existing sessions
	/// retain the locator their hello signed.
	pub fn set_advertised_locator(&self, locator: &Locator) -> Result<()> {
		self.shared.set_advertised_locator(locator)
	}

	/// Remove this Host's retained locator for `transport`.
	pub fn remove_advertised_locator(&self, transport: &str) -> Result<()> {
		self.shared.remove_advertised_locator(transport)
	}

	/// The canonical key designator (64 lowercase hex digits) for this host's
	/// identity seed: what a keyed-tcp locator names as its designator.
	pub fn designator(&self) -> Result<String> {
		let mut out = [0u8; 64];
		// SAFETY: `self.shared.seed` is the Host's `[u8; 32]` identity seed, live for the call, and the callee reads
		// `seed.len()` bytes from it; `out` is a local `[u8; 64]` the callee writes at most `out.len()` bytes into.
		check_host(unsafe {
			ffi::glowcap_host_designator_from_seed(
				self.shared.seed.as_ptr(),
				self.shared.seed.len(),
				out.as_mut_ptr(),
				out.len(),
			)
		})?;
		Ok(String::from_utf8_lossy(&out).into_owned())
	}

	/// A Host with a fresh durable identity inside a caller-supplied
	/// allocation scope: every FFI allocation the Host makes routes through
	/// the context's allocator, and the Host must be dropped before the
	/// context. This is the same attachment the Python and TypeScript bindings
	/// offer at Host construction.
	pub fn new_in(context: &Context, options: HostOptions) -> Result<Host> {
		let mut seed = [0u8; 32];
		getrandom::fill(&mut seed).map_err(|_| Error::with_detail(sys::ERR_INTERNAL, "no OS entropy".to_string()))?;
		Host::from_seed_with_options_in(seed, options, context)
	}

	/// [`Self::from_seed_with_options`] inside a caller-supplied allocation scope.
	/// See [`Self::new_in`] for the ownership order.
	pub fn from_seed_with_options_in(seed: [u8; 32], options: HostOptions, context: &Context) -> Result<Host> {
		Ok(Host {
			shared: HostShared::new(
				seed,
				options.codec,
				options.captp_version,
				options.features,
				options.local_turn_budget,
				Some(context),
			)?,
		})
	}

	pub(crate) fn from_shared(shared: Rc<HostShared>) -> Host {
		Host { shared }
	}

	pub(crate) fn shared(&self) -> Rc<HostShared> {
		Rc::clone(&self.shared)
	}

	/// Atomically install explicit byte-fed connectors on this Host. The Host
	/// retains one connector per transport symbol so later handoff redeem uses
	/// the same caller-selected channel authority.
	pub fn install_connectors(&self, connectors: &[crate::Connector]) -> Result<()> {
		self.shared.install_connectors(connectors)
	}

	/// Enliven a complete sturdyref without naming a session (ADR-0007): the
	/// host enlivens it over a live session it already dialed to that peer, or
	/// dials one itself through this host's own DIAL action and finishes when
	/// the dial reports. [`Session::enliven`] is the narrower verb: it never
	/// dials, and refuses a sturdyref for another peer. Each returned occurrence
	/// releases its application retain on final drop.
	pub async fn enliven(&self, sturdyref: &str) -> Result<Ref> {
		self.enliven_inner(sturdyref, None).await
	}

	/// Enliven a sturdyref whose swiss spelling is defined by `captp_version`,
	/// while this Host still owns live-session selection and dialing.
	pub async fn enliven_for_version(&self, sturdyref: &str, captp_version: CaptpVersion) -> Result<Ref> {
		self.enliven_inner(sturdyref, Some(captp_version)).await
	}

	/// Retain the live exporter session of a capability in this Host. Local,
	/// stale and foreign-Host capabilities have no exporter. The returned owned
	/// handle shares the existing session. It does not dial or add authority.
	/// Use [`Session::relinquish`] to relinquish it without closing other owners.
	pub fn reference_session(&self, reference: &Ref) -> Result<Option<Session>> {
		Ok(self.shared.exporter_for(reference)?.map(Session::owning))
	}

	/// Fetch a named publication at a typed locator. This Host's configured
	/// profile owns version, codec, route admission, and physical dial selection.
	/// Each returned occurrence releases its application retain on final drop.
	pub async fn fetch_at(&self, locator: &Locator, name: &str) -> Result<Ref> {
		self.shared.guard_handle()?;
		let owned = OwnedLocator::new(locator)?;
		let mut vow: u64 = 0;
		// SAFETY: `self.shared.raw()` is the `GlowcapHost` handle owned by this Host's `HostShared`, proven non-null by
		// `guard_handle` above; `owned.borrow_view()?` is a view into the `OwnedLocator` local, which is dropped only
		// after the call, and `name` is a `&str` borrowed for the call; the header says the locator and name are
		// borrowed and staged work keeps its own copy. `vow` is a local out-parameter the callee fills.
		check_host(unsafe {
			ffi::glowcap_host_fetch_at(
				self.shared.raw(),
				owned.borrow_view()?,
				name.as_ptr(),
				name.len(),
				&mut vow,
			)
		})?;
		drop(owned);
		self.shared.owned_vow_minted(vow);
		let _release = crate::gc::VowGuard::new(&self.shared, vow);
		match self.shared.observe_vow(vow).await? {
			Argument::Reference(reference) => Ok(reference),
			_ => Err(Error::broken(format!(
				"publication {name:?} did not resolve to a capability"
			))),
		}
	}

	async fn enliven_inner(&self, sturdyref: &str, captp_version: Option<CaptpVersion>) -> Result<Ref> {
		self.shared.guard_handle()?;
		let mut vow: u64 = 0;
		// SAFETY: `self.shared.raw()` is the `GlowcapHost` handle owned by this Host's `HostShared`, proven non-null by
		// `guard_handle` above; `sturdyref` is a `&str` borrowed for the call and `vow` is a local out-parameter the
		// callee fills in either arm.
		check_host(unsafe {
			match captp_version {
				Some(version) => ffi::glowcap_host_enliven_for_version(
					self.shared.raw(),
					version.to_c(),
					sturdyref.as_ptr(),
					sturdyref.len(),
					&mut vow,
				),
				None => ffi::glowcap_host_enliven(self.shared.raw(), sturdyref.as_ptr(), sturdyref.len(), &mut vow),
			}
		})?;
		// The vow may be parked on a dial with no session of its own, which is
		// exactly the `None` session row the vow table already admits.
		// Host-level results own one application occurrence even without an
		// arrival Session. Track it before progress, including cache hits and
		// completed replies whose observer is subsequently cancelled.
		self.shared.owned_vow_minted(vow);
		let _release = crate::gc::VowGuard::new(&self.shared, vow);
		match self.shared.observe_vow(vow).await? {
			Argument::Reference(reference) => Ok(reference),
			_ => Err(Error::broken(format!("{sturdyref:?} did not resolve to a capability"))),
		}
	}
}
