//! Host publication: named and durable actors, published references, and
//! the resolver that settles a deferred turn.
use super::*;

impl Host {
	/// Atomically defer the current behavior turn onto a fresh resolver vow
	/// (off-turn settlement, ADR-0102). The returned [`Resolver`] is the
	/// one-shot settle authority. Refusal publishes neither half of the pair.
	pub fn defer_turn(&self) -> Result<Resolver> {
		let turn = current_turn_for(Rc::as_ptr(&self.shared) as usize).ok_or_else(|| {
			Error::with_transport_detail(
				sys::ERR_INVALID_ARGUMENT,
				Some("defer_turn is a turn verb: call it inside a behavior of this host".into()),
			)
		})?;
		let mut resolver_id: u64 = 0;
		// SAFETY: `turn` is the `GlowcapHostTurn` of the behavior callback now running on this thread for this host,
		// which `current_turn_for` keyed by `self.shared`, and it stays valid until that callback returns;
		// `resolver_id` is a local out-parameter the callee writes.
		check_host(unsafe { ffi::glowcap_host_turn_defer(turn, &mut resolver_id) })?;
		Ok(Resolver {
			shared: Rc::clone(&self.shared),
			id: Some(resolver_id),
		})
	}

	/// Defer a call that has an answer. Tells return None and mint no resolver.
	/// Both paths use the current Host turn's actual delivery provenance.
	pub fn defer_turn_if_answer(&self) -> Result<Option<Resolver>> {
		let turn = current_turn_for(Rc::as_ptr(&self.shared) as usize).ok_or_else(|| {
			Error::with_transport_detail(
				sys::ERR_INVALID_ARGUMENT,
				Some("defer_turn_if_answer requires a behavior turn of this host".into()),
			)
		})?;
		let mut id = 0;
		// SAFETY: `turn` is the `GlowcapHostTurn` of the behavior callback now running on this thread for this host,
		// which `current_turn_for` keyed by `self.shared`, and it stays valid until that callback returns; `id` is a
		// local out-parameter the callee writes.
		check_host(unsafe { ffi::glowcap_host_turn_defer_if_answer(turn, &mut id) })?;
		Ok((id != 0).then(|| Resolver {
			shared: self.shared.clone(),
			id: Some(id),
		}))
	}

	/// Host `make`'s behavior once and bind `name` as a Host-wide alias. Fetch
	/// lazily projects the actor onto a session, and a deposited gift keeps that
	/// exact actor when a recipient withdraws over its own exporter session
	/// (ADR-0009). `make` preserves the factory-shaped API for a `!Clone` `FnMut`.
	/// The Host invokes it once.
	pub fn publish(&self, name: &str, make: impl FnOnce() -> Behavior) -> Result<()> {
		self.shared.guard_handle()?;
		// A Host publication is bound to no single session: its forwards always go
		// through the host, and a turn it runs belongs to whichever session
		// the deliver arrived on.
		let mut behavior = make();
		let cell = self
			.shared
			.actor_cell(outcome_behavior(move |verb, args| behavior(verb, args)))?;
		// SAFETY: `cell` is the fresh unregistered `ActorCell` that `self.shared.actor_cell` just boxed, so nothing
		// else holds it; the closure makes the one `glowcap_host_publish` call, and `Host` is `!Send`, so no other
		// thread touches the host or cell during it. The closure's `self.shared.raw.get()` is non-null (`guard_handle`
		// above), this `HostShared`'s handle from `glowcap_host_new_in`; `name` borrows the caller's `&str` for the
		// call, and the callee copies it. `trampoline` and `ctx_free` are the binding's callbacks for an `ActorCell`,
		// whose ownership passes to the host on success.
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
	/// return that name: the swiss to place in a sturdyref beside this host's
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
	/// unpredictable entropy. The Zig Host owns name derivation and refuses a
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
		// SAFETY: `cell` is the fresh unregistered `ActorCell` that `self.shared.actor_cell` just boxed, so nothing
		// else holds it; the closure makes the one `glowcap_host_publish_durable` call, and `Host` is `!Send`, so no
		// other thread touches the host or cell during it. The closure's `self.shared.raw.get()` is non-null
		// (`guard_handle` above), this `HostShared`'s handle from `glowcap_host_new_in`; `entropy` is a local array
		// borrowed for the call and read only during it, and `swiss` is a local array of the swiss length the callee
		// writes. `trampoline` and `ctx_free` are the binding's callbacks for an `ActorCell`, whose ownership passes to
		// the host on success.
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

	/// Publish the exact held local actor without creating a forwarding actor.
	/// The publication owns a separate root until `remove_durable`. The input
	/// occurrence remains owned by its caller on every outcome.
	pub fn publish_reference_with_entropy(
		&self,
		reference: &Ref,
		entropy: [u8; Self::DURABLE_ENTROPY_BYTES],
	) -> Result<String> {
		self.shared.guard_handle()?;
		self.shared.exporter_for(reference)?;
		let reference = reference.to_sys()?;
		let mut swiss = [0u8; crate::abi_constants_gen::HOST_DURABLE_SWISS_LEN];
		// SAFETY: `self.shared.raw.get()` is non-null (`guard_handle` above), this `HostShared`'s handle from
		// `glowcap_host_new_in`; `reference` is a local `GlowcapReference` from `Ref::to_sys`, and `entropy` is a local
		// array, both borrowed for the call and read only during it; `swiss` is a local array of the swiss length the
		// callee writes.
		let written = unsafe {
			ffi::glowcap_host_publish_reference(
				self.shared.raw.get(),
				&reference,
				entropy.as_ptr(),
				entropy.len(),
				swiss.as_mut_ptr(),
				swiss.len(),
			)
		};
		if written != swiss.len() as i32 {
			check_host(written)?;
			return Err(Error::with_detail(
				sys::ERR_INTERNAL,
				"publication returned an invalid name length".into(),
			));
		}
		String::from_utf8(swiss.to_vec())
			.map_err(|_| Error::with_detail(sys::ERR_INTERNAL, "publication returned an invalid name".into()))
	}

	/// Remove a minted durable publication (ADR-0098): the sturdyref
	/// misses afterward, while capabilities already issued and deposited
	/// gifts keep the exact actor. Returns `false` when no such durable name
	/// exists.
	pub fn remove_durable(&self, swiss: &str) -> Result<bool> {
		self.shared.guard_handle()?;
		// SAFETY: `self.shared.raw.get()` is non-null (`guard_handle` above), this `HostShared`'s handle from
		// `glowcap_host_new_in`; `swiss` borrows the caller's `&str` for the call, and the callee reads it only during
		// the call.
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
	/// life. Returns `false` when no such alias exists. Every other refusal is
	/// returned with its native diagnostic.
	pub fn unpublish(&self, name: &str) -> Result<bool> {
		self.shared.guard_handle()?;
		// SAFETY: as `remove_durable` above for the handle; `name` borrows the caller's `&str` for the call, and the
		// callee reads it only during the call.
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
/// A successful settle consumes its native authority. A refused conversion or
/// native call leaves the resolver retryable. `fulfill` carries plain data.
/// `fulfill_value` projects owning-thread capabilities in the original caller
/// session. Owning values use ordinary handoff staging. Dropping an unsettled resolver
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
	/// Top-level: refused inside a behavior callback. The settle pumps the
	/// sessions the deferred answers dirtied. A refused conversion or native
	/// settle leaves this resolver live so the caller can retry or break it.
	pub fn fulfill(&mut self, value: &Argument) -> Result<()> {
		let id = self.live_id()?;
		let mut arena = crate::SendArena::default();
		let c_value = arena.one(value)?;
		// SAFETY: `self.shared.raw.get()` is this `HostShared`'s handle from `glowcap_host_new_in`, kept alive by the
		// `Rc` this `Resolver` holds, and a handle nulled by teardown is refused by the callee as a null host;
		// `c_value` is a `GlowcapArgument` the local `arena` built from `value`, borrowed for the call, and the callee
		// reads it only during the call.
		check_host(unsafe { ffi::glowcap_host_resolver_fulfill(self.shared.raw.get(), id, &c_value) })?;
		self.id = None;
		// A settle can advance a FINISH close; wake any parked close driver.
		self.shared.note_close_activity();
		self.shared.schedule_kick()?;
		Ok(())
	}

	/// Fulfill on the Host owner thread with data and capabilities reachable in
	/// the original caller session and ordinary handoff staging. Failed
	/// preparation leaves this resolver available for retry or explicit break.
	pub fn fulfill_value(&mut self, value: &Argument) -> Result<()> {
		let id = self.live_id()?;
		let mut arena = crate::SendArena::default();
		let c_value = arena.one(value)?;
		// SAFETY: as `fulfill` above; `c_value` is a `GlowcapArgument` the local `arena` built from `value`, borrowed
		// for the call, and the callee reads it only during the call.
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
		// SAFETY: as `fulfill` above for the handle; `reason` borrows the caller's `&str` for the call, and the callee
		// reads it only during the call.
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
