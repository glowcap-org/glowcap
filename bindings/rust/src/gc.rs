//! Host reference, vow, and abandoned-reply retirement. Distributed reference
//! GC (ADR-0063) is opt-in; vow and deferred-reply cleanup are always active.
//! Owns the
//! [`CapabilityGuard`] death rite, recursive application-value tracking, and the
//! `glowcap_host_ref_release` drain. Session holds only the opt-in flag; the
//! Host owns the pending queue because a Ref may outlive its arrival session.

use std::cell::Cell;
use std::rc::{Rc, Weak};

use crate::Argument;
use crate::Ref;
use crate::host::HostShared;
use crate::session_shared::SessionShared;
use crate::sys::host as ffi;

/// Drops to one parked `glowcap_host_ref_release` delta of 1 for a Host id.
/// The drop only parks the id and schedules the Host action drain —
/// it may run inside a behavior trampoline (a behavior dropping a `Ref`), where
/// the host-driving verbs are refused, so the release itself always runs on the
/// pumping task, never here.
#[derive(Debug)]
pub(crate) struct CapabilityGuard {
	pub(crate) token: u64,
	pub(crate) host: Weak<HostShared>,
	armed: Cell<bool>,
}

/// One public Host vow's release right. The wrapper may die inside a behavior,
/// so Drop only parks the id; the owner-loop drain performs the C call.
pub(crate) struct VowGuard {
	vow: u64,
	host: Weak<HostShared>,
}

impl VowGuard {
	pub(crate) fn new(host: &Rc<HostShared>, vow: u64) -> Self {
		Self {
			vow,
			host: Rc::downgrade(host),
		}
	}
}

impl Drop for VowGuard {
	fn drop(&mut self) {
		if let Some(host) = self.host.upgrade() {
			if host.raw().is_null() {
				return;
			}
			host.vow_gc_pending.borrow_mut().push_back(self.vow);
			host.schedule_kick_or_record();
		}
	}
}

impl Drop for CapabilityGuard {
	fn drop(&mut self) {
		if self.armed.get()
			&& let Some(host) = self.host.upgrade()
		{
			if host.raw().is_null() {
				return;
			}
			host.gc_pending.borrow_mut().push_back(self.token);
			host.schedule_kick_or_record();
		}
	}
}

/// Drain the parked GC releases: one release delta per reclaimed token. The
/// op:gc-exports flush rides the kick `CapabilityGuard::drop` scheduled when it
/// parked the id, so the drain itself never kicks. A token leaves the queue
/// only after its native release commits. Called at the head of Host progress
/// and whenever a finalizer schedules it.
pub(crate) fn drain(host: &HostShared) -> crate::Result<()> {
	if let Some(failure) = host.take_background_failure() {
		return Err(failure);
	}
	if host.raw().is_null() {
		retire(host);
		return Ok(());
	}
	loop {
		let Some(token) = host.gc_pending.borrow().front().copied() else {
			break;
		};
		let raw = crate::sys::GlowcapReference { id: token };
		crate::host::check_host(unsafe { ffi::glowcap_host_ref_release(host.raw(), &raw, 1) })?;
		host.gc_pending.borrow_mut().pop_front();
	}
	loop {
		let Some(vow) = host.vow_gc_pending.borrow().front().copied() else {
			break;
		};
		host.abandon_vow(vow);
		crate::host::check_host(unsafe { ffi::glowcap_host_vow_release(host.raw(), vow) })?;
		host.vow_gc_pending.borrow_mut().pop_front();
	}
	loop {
		let Some(resolver) = host.resolver_abandon_pending.borrow().front().copied() else {
			return Ok(());
		};
		let reason = b"deferred reply owner was dropped";
		crate::host::check_host(unsafe {
			ffi::glowcap_host_resolver_abandon(host.raw(), resolver, reason.as_ptr(), reason.len())
		})?;
		host.resolver_abandon_pending.borrow_mut().pop_front();
	}
}

/// Drop binding queues after their native Host owner has been consumed.
pub(crate) fn retire(host: &HostShared) {
	host.gc_pending.borrow_mut().clear();
	host.vow_gc_pending.borrow_mut().clear();
	host.resolver_abandon_pending.borrow_mut().clear();
}

pub(crate) fn owned_guard(host: &Rc<HostShared>, id: u64) -> Rc<CapabilityGuard> {
	Rc::new(CapabilityGuard {
		token: id,
		host: Rc::downgrade(host),
		armed: Cell::new(true),
	})
}

pub(crate) fn disarm(reference: &Ref) {
	if let Some(guard) = reference.guard() {
		guard.armed.set(false);
	}
}

/// Attach one finalizer unit to every capability occurrence in a value the
/// native Host has just projected to this GC-enabled session. The walk mutates
/// only `Ref` leaves; container identity and application data stay unchanged.
/// Each native occurrence owns one Host retain, so repeated equal ids remain
/// distinct guards rather than being deduplicated in the binding.
pub(crate) fn track_argument(shared: &Rc<SessionShared>, argument: &mut Argument) {
	if !shared.gc.get() {
		return;
	}
	track_owned_argument(&shared.host, argument);
}

/// Track an application-owned projection, independent of a Session opt-in.
pub(crate) fn track_owned_argument(host: &Rc<HostShared>, argument: &mut Argument) {
	match argument {
		Argument::Reference(reference) => {
			if reference.guard().is_none() {
				reference.attach_guard(owned_guard(host, reference.id()));
			}
		}
		Argument::List(items) | Argument::Set(items) => {
			for item in items {
				track_owned_argument(host, item);
			}
		}
		Argument::Tagged { value, .. } => {
			for item in value {
				track_owned_argument(host, item);
			}
		}
		Argument::Struct(entries) => {
			for (_, value) in entries {
				track_owned_argument(host, value);
			}
		}
		Argument::Integer(_)
		| Argument::Float(_)
		| Argument::Boolean(_)
		| Argument::Bytes(_)
		| Argument::String(_)
		| Argument::Symbol(_)
		| Argument::Error(_)
		| Argument::Keyword(_)
		| Argument::Void
		| Argument::BigInteger { .. } => {}
	}
}

pub(crate) fn track_arguments(shared: &Rc<SessionShared>, arguments: &mut [Argument]) {
	for argument in arguments {
		track_argument(shared, argument);
	}
}

/// Release one capability retain deterministically, because the application says it is
/// done with the capability rather than because a handle dropped.
///
/// Lives here beside the finalizer path because both end in the same Host verb.
pub(crate) fn release_ref(host_raw: *mut crate::sys::host::GlowcapHost, id: u64) -> crate::Result<()> {
	let raw = crate::sys::GlowcapReference { id };
	let rc = unsafe { crate::sys::host::glowcap_host_ref_release(host_raw, &raw, 1) };
	crate::host::check_host(rc)
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn refused_release_stays_queued_and_background_cause_surfaces_once() {
		let owner = crate::Host::new_host();
		let host = owner.shared();
		host.gc_pending.borrow_mut().push_back(u64::MAX);

		let refusal = drain(&host).expect_err("an unknown Host capability must be refused");
		assert_eq!(host.gc_pending.borrow().front(), Some(&u64::MAX));

		host.record_background_failure(refusal.clone());
		assert_eq!(drain(&host).unwrap_err(), refusal);
		assert_eq!(host.gc_pending.borrow().front(), Some(&u64::MAX));

		let retry = drain(&host).expect_err("the retained token must be retried");
		assert_eq!(retry, refusal);
		assert_eq!(host.gc_pending.borrow().front(), Some(&u64::MAX));
	}

	#[test]
	fn retirement_discards_queues_without_native_work() {
		let owner = crate::Host::new_host();
		let host = owner.shared();
		host.gc_pending.borrow_mut().push_back(17);
		host.vow_gc_pending.borrow_mut().push_back(19);
		host.resolver_abandon_pending.borrow_mut().push_back(23);

		retire(&host);

		assert!(host.gc_pending.borrow().is_empty());
		assert!(host.vow_gc_pending.borrow().is_empty());
		assert!(host.resolver_abandon_pending.borrow().is_empty());
	}
}
