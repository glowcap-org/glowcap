//! Public Host construction, publication, identity, and resolver surface.

use super::*;
use crate::{CaptpVersion, Session};
/// The CapTP Host: one identity, one actor graph, one routing and redeem
/// authority, shared by every session minted against it. Owns `engine.Node`
/// (router half of Goblins mycapn; Host carries the product role — ADR-0079).
/// The cross-session machinery lives in the Zig core behind `libglowcap_host`
/// (ADR-0072); this is the host-idiom residue over it — the session registry,
/// the vow table, the action drain that performs the I/O the host asks for
/// (dial, flush, settle, entropy), and the iroh redeem posture. Cloning shares
/// the same Host; the native host is released when the last clone (and last
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

#[cfg(any(feature = "tcp", feature = "iroh", feature = "onion", feature = "relay"))]
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
/// local-turn budget are mint-time; each session settles version and codec with
/// its partner, falling back to v1.0/Syrup when needed, and runs only the
/// intersection of the two offered feature sets. Selective session limits stay
/// on [`Host::set_session_limits`] (ADR-0124).
#[derive(Debug, Clone, Copy, Default)]
pub struct HostOptions {
	pub codec: Codec,
	/// The CapTP profile this Host prefers; see
	/// [`CaptpVersion`](crate::CaptpVersion).
	pub captp_version: crate::CaptpVersion,
	/// Optional CapTP features this Host advertises.
	pub features: crate::FeatureSet,
	/// `0` = unbounded (default); nonzero caps local-turn amplification per drive
	/// (ADR-0076).
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
/// preserve the Host's current value; the durable sent-answer budget remains
/// separate from transient outbound flow pressure.
#[derive(Debug, Clone, Copy, Default)]
pub struct SessionLimitOptions {
	pub max_frame_bytes: usize,
	pub queue_cap: usize,
	pub outbound_high_water_bytes: usize,
	pub max_retained_sent_answer_bytes: u32,
}

impl Host {
	/// Close every session this host holds, then release the native Host and its
	/// hosted callbacks. Every clone becomes closed. When called by a hosted
	/// behavior, teardown is parked until that callback returns.
	///
	/// Closing a [`Session`](crate::Session) closes that one connection and
	/// nothing else, so this is how an application that shares one host across
	/// several sessions tears the whole thing down. The returned future is the
	/// completion barrier for Host-owned work and native state.
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

	/// A fresh Host whose sessions all negotiate in `codec` — the codec is a
	/// Host property, so every session minted against a shared Host speaks
	/// the same grammar. Pass the Host to
	/// [`RuntimeConfig::adopt_host`](crate::RuntimeConfig::adopt_host),
	/// or, with native TCP enabled, to `tcp::listen` through `tcp::ListenOptions`.
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
	/// session still receives a fresh signing key (ADR-0075, ADR-0097).
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

	/// Claim every callerless failure retained by this Host's allocation
	/// context. This is the same queue a caller-supplied [`Context`] exposes;
	/// returned and close-barrier failures are not duplicated here.
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
	/// sessions advertise it regardless of their transport; existing sessions
	/// retain the locator their hello signed.
	pub fn set_advertised_locator(&self, locator: &Locator) -> Result<()> {
		self.shared.set_advertised_locator(locator)
	}

	/// Remove this Host's retained locator for `transport`.
	pub fn remove_advertised_locator(&self, transport: &str) -> Result<()> {
		self.shared.remove_advertised_locator(transport)
	}

	/// The canonical key designator (64 lowercase hex digits) for this host's
	/// identity seed — what a keyed-tcp locator names as its designator.
	pub fn designator(&self) -> Result<String> {
		let mut out = [0u8; 64];
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
	/// allocation scope: every native allocation the Host makes routes through
	/// the context's allocator, and the Host must be dropped before the
	/// context. This is the same attachment the Python and TypeScript bindings
	/// offer at Host construction.
	pub fn new_in(context: &Context, options: HostOptions) -> Result<Host> {
		let mut seed = [0u8; 32];
		getrandom::fill(&mut seed).map_err(|_| Error::with_detail(sys::ERR_INTERNAL, "no OS entropy".to_string()))?;
		Host::from_seed_with_options_in(seed, options, context)
	}

	/// [`Self::from_seed_with_options`] inside a caller-supplied allocation scope;
	/// see [`Self::new_in`] for the ownership order.
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

	/// Enliven a complete sturdyref without naming a session (ADR-0098): the
	/// host enlivens it over a live session it already dialed to that peer, or
	/// dials one itself through this host's own DIAL action and finishes when
	/// the dial reports. [`Session::enliven`] is the narrower verb — it never
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
	/// handle shares the existing session; it does not dial or add authority.
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
		let settled = self.shared.await_vow(vow);
		self.shared.kick_actions().await?;
		match settled.await? {
			Argument::Reference(reference) => Ok(reference),
			_ => Err(Error::broken(format!(
				"publication {name:?} did not resolve to a capability"
			))),
		}
	}

	async fn enliven_inner(&self, sturdyref: &str, captp_version: Option<CaptpVersion>) -> Result<Ref> {
		self.shared.guard_handle()?;
		let mut vow: u64 = 0;
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
		let settled = self.shared.await_vow(vow);
		self.shared.kick_actions().await?;
		match settled.await? {
			Argument::Reference(reference) => Ok(reference),
			_ => Err(Error::broken(format!("{sturdyref:?} did not resolve to a capability"))),
		}
	}

	/// Atomically defer the current behavior turn onto a fresh resolver vow
	/// (off-turn settlement, ADR-0102). The returned [`Resolver`] is the
	/// one-shot settle authority; refusal publishes neither half of the pair.
	pub fn defer_turn(&self) -> Result<Resolver> {
		let turn = current_turn_for(Rc::as_ptr(&self.shared) as usize).ok_or_else(|| {
			Error::with_transport_detail(
				sys::ERR_INVALID_ARGUMENT,
				Some("defer_turn is a turn verb: call it inside a behavior of this host".into()),
			)
		})?;
		let mut resolver_id: u64 = 0;
		check_host(unsafe { ffi::glowcap_host_turn_defer(turn, &mut resolver_id) })?;
		Ok(Resolver {
			shared: Rc::clone(&self.shared),
			id: Some(resolver_id),
		})
	}

	/// Host `make`'s behavior once and bind `name` as a Host-wide alias. Fetch
	/// lazily projects the actor onto a session, and a deposited gift keeps that
	/// exact actor when a recipient withdraws over its own exporter session
	/// (ADR-0009). `make` preserves the factory-shaped API for a `!Clone` `FnMut`;
	/// the Host invokes it once.
	pub fn publish_giftable(&self, name: &str, make: impl FnOnce() -> Behavior) -> Result<()> {
		self.shared.guard_handle()?;
		// A giftable is bound to no single session: its forwards always go
		// through the host, and a turn it runs belongs to whichever session
		// the deliver arrived on.
		let mut behavior = make();
		let cell = self
			.shared
			.actor_cell(outcome_behavior(move |verb, args| behavior(verb, args)))?;
		unsafe {
			register_actor_cell(
				cell,
				|| {
					ffi::glowcap_host_publish(
						self.shared.raw.get(),
						name.as_ptr(),
						name.len(),
						trampoline,
						cell as *mut core::ffi::c_void,
						ctx_free,
					)
				},
				|code| code == sys::OK,
			)?;
		}
		Ok(())
	}

	/// Publish `make`'s behavior under a freshly minted durable swiss name and
	/// return that name — the swiss to place in a sturdyref beside this host's
	/// own locator (ADR-0098). Unpredictable, never reassigned, structurally
	/// disjoint from every mutable alias, and removable only through
	/// [`Host::remove_durable`]. Entropy is drawn here, from the platform RNG.
	pub fn publish_durable(&self, make: impl FnOnce() -> Behavior) -> Result<String> {
		self.shared.guard_handle()?;
		let mut entropy = [0u8; Self::DURABLE_ENTROPY_BYTES];
		getrandom::fill(&mut entropy).map_err(|error| {
			Error::with_detail(sys::ERR_IO, format!("drawing durable swiss entropy failed: {error}"))
		})?;
		self.publish_durable_with_entropy(entropy, make)
	}

	/// Required entropy width, reflected from the Host C ABI.
	pub const DURABLE_ENTROPY_BYTES: usize = crate::abi_constants_gen::HOST_DURABLE_ENTROPY_LEN;

	/// Publish with retained or cryptographically derived entropy so a durable
	/// name can be restored after reconstructing the Host. The caller supplies
	/// unpredictable entropy; the Zig Host owns name derivation and refuses a
	/// collision with a live publication. Removing a publication releases its
	/// name: the application must retain revocation records and never reuse that
	/// entropy for different authority. Restore both identity and publication
	/// state before serving callers.
	pub fn publish_durable_with_entropy(
		&self,
		entropy: [u8; Self::DURABLE_ENTROPY_BYTES],
		make: impl FnOnce() -> Behavior,
	) -> Result<String> {
		self.shared.guard_handle()?;
		let expected_len = i32::try_from(crate::abi_constants_gen::HOST_DURABLE_SWISS_LEN).map_err(|_| {
			Error::with_detail(
				sys::ERR_INTERNAL,
				"durable swiss length exceeds the C ABI result range".into(),
			)
		})?;
		let mut behavior = make();
		let cell = self
			.shared
			.actor_cell(outcome_behavior(move |verb, args| behavior(verb, args)))?;
		let mut swiss = [0u8; crate::abi_constants_gen::HOST_DURABLE_SWISS_LEN];
		unsafe {
			register_actor_cell(
				cell,
				|| {
					ffi::glowcap_host_publish_durable(
						self.shared.raw.get(),
						entropy.as_ptr(),
						entropy.len(),
						trampoline,
						cell as *mut core::ffi::c_void,
						ctx_free,
						swiss.as_mut_ptr(),
						swiss.len(),
					)
				},
				|code| code == expected_len,
			)?
		};
		let name = String::from_utf8_lossy(&swiss).into_owned();
		Ok(name)
	}

	/// Remove a minted durable publication (ADR-0098): the old sturdyref
	/// misses from now on, while capabilities already issued and deposited
	/// gifts keep the exact actor. Returns `false` when no such durable name
	/// exists.
	pub fn remove_durable(&self, swiss: &str) -> Result<bool> {
		self.shared.guard_handle()?;
		let rc = unsafe { ffi::glowcap_host_remove_durable(self.shared.raw.get(), swiss.as_ptr(), swiss.len()) };
		if rc == sys::ERR_NOT_FOUND {
			return Ok(false);
		}
		check_host(rc)?;
		Ok(true)
	}

	/// Remove the Host-wide alias `name` (alias-only, ADR-0096): a later fetch
	/// misses on every session, while capabilities already issued and deposited
	/// gifts keep the exact actor, whose behavior stays hosted for the Host's
	/// life. Returns `false` when no such alias exists; every other refusal is
	/// returned with its native diagnostic.
	pub fn unpublish_giftable(&self, name: &str) -> Result<bool> {
		self.shared.guard_handle()?;
		let rc = unsafe { ffi::glowcap_host_unpublish(self.shared.raw.get(), name.as_ptr(), name.len()) };
		if rc == sys::ERR_NOT_FOUND {
			return Ok(false);
		}
		check_host(rc)?;
		// The alias is gone but the actor is not: the C row still owns the
		// behavior cell (freed at release), so only the name bookkeeping drops.
		Ok(true)
	}
}
/// The settle authority of a resolver pair (off-turn settlement, ADR-0102),
/// minted while [`Host::defer_turn`] atomically defers a behavior's answer.
/// The behavior hands the resolver to whatever completes the work, and the
/// completion settles it from the host's thread.
/// A successful settle consumes its native authority; a refused conversion or
/// native call leaves the resolver retryable. `fulfill` carries plain data;
/// `fulfill_value` projects owning-thread capabilities in the original caller
/// session. Cross-session handoffs use ordinary send/forward machinery. Dropping an unsettled resolver
/// schedules a broken answer through the Host, including drops inside callbacks.
pub struct Resolver {
	shared: Rc<HostShared>,
	id: Option<u64>,
}

impl Resolver {
	fn live_id(&self) -> Result<u64> {
		self.id.ok_or_else(|| {
			Error::with_transport_detail(sys::ERR_INVALID_ARGUMENT, Some("resolver already settled".into()))
		})
	}

	/// Settle the deferred answer fulfilled with a capability-free `value`.
	/// Top-level: refused inside a behavior callback; the settle pumps the
	/// sessions the deferred answers dirtied. A refused conversion or native
	/// settle leaves this resolver live so the caller can retry or break it.
	pub fn fulfill(&mut self, value: &Argument) -> Result<()> {
		let id = self.live_id()?;
		let mut arena = crate::SendArena::default();
		let c_value = arena.one(value)?;
		check_host(unsafe { ffi::glowcap_host_resolver_fulfill(self.shared.raw.get(), id, &c_value) })?;
		self.id = None;
		// A settle can advance a FINISH close; wake any parked close driver.
		self.shared.note_close_activity();
		self.shared.schedule_kick()?;
		Ok(())
	}

	/// Fulfill on the Host owner thread with data and capabilities reachable in
	/// the original caller session. Cross-session handoffs are refused; failed
	/// preparation leaves this resolver available for retry or explicit break.
	pub fn fulfill_value(&mut self, value: &Argument) -> Result<()> {
		let id = self.live_id()?;
		let mut arena = crate::SendArena::default();
		let c_value = arena.one(value)?;
		check_host(unsafe { ffi::glowcap_host_resolver_fulfill_value(self.shared.raw.get(), id, &c_value) })?;
		self.id = None;
		self.shared.note_close_activity();
		self.shared.schedule_kick()?;
		Ok(())
	}

	/// Settle the deferred answer broken with the worker's own words. The
	/// same top-level, one-shot contract as [`Resolver::fulfill`].
	pub fn break_with(&mut self, reason: &str) -> Result<()> {
		let id = self.live_id()?;
		check_host(unsafe {
			ffi::glowcap_host_resolver_break(self.shared.raw.get(), id, reason.as_ptr(), reason.len())
		})?;
		self.id = None;
		// A settle can advance a FINISH close; wake any parked close driver.
		self.shared.note_close_activity();
		self.shared.schedule_kick()?;
		Ok(())
	}
}

// A resolver may be dropped from a behavior callback. Like capability/vow
// finalizers, park its native operation for the Host's safe progress boundary.
impl Drop for Resolver {
	fn drop(&mut self) {
		if let Some(id) = self.id.take()
			&& !self.shared.raw().is_null()
		{
			self.shared.resolver_abandon_pending.borrow_mut().push_back(id);
			self.shared.schedule_kick_or_record();
		}
	}
}
