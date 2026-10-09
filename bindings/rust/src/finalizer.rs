//! Failure-cold ownership for native releases refused from Rust `Drop` paths.
//!
//! One safe boundary claims a finite queue prefix. A refusal requeues its
//! owner for the next boundary rather than spinning; native allocation policy
//! stays retained until the consuming release call.

use std::cell::RefCell;
use std::collections::VecDeque;
use std::mem::ManuallyDrop;
use std::rc::Rc;

use crate::context::ContextInner;
use crate::host::{HostShared, check_host};
use crate::session_shared::SessionShared;
#[cfg(not(target_arch = "wasm32"))]
use crate::sys::driver::GlowcapDriverLoop;
use crate::sys::{self, host as ffi_host};
use crate::{Error, FailureLayer, FailureScope, Result};

enum PendingRelease {
	#[cfg(feature = "loam")]
	Loam(Rc<crate::loam::AttachmentInner>),
	#[cfg(feature = "loam")]
	LoamWork {
		owner: Rc<crate::loam::AttachmentInner>,
		raw: *mut crate::sys::loam::GlowcapLoamWork,
	},
	#[cfg(feature = "loam")]
	LoamEffectExecution {
		owner: Rc<crate::loam::AttachmentInner>,
		raw: *mut crate::sys::loam::GlowcapLoamEffectExecution,
	},
	#[cfg(all(feature = "loam", not(target_arch = "wasm32")))]
	LoamStore(*mut crate::sys::loam::GlowcapLoamLmdb),
	#[cfg(all(feature = "loam", target_arch = "wasm32"))]
	BrowserLoamStore {
		backend: crate::loam::browser::Storage,
		store: *mut crate::sys::loam::GlowcapLoamStore,
	},
	Session(Rc<SessionShared>),
	Host {
		raw: *mut ffi_host::GlowcapHost,
		context: Option<Rc<ContextInner>>,
		refusal_reported: bool,
	},
	#[cfg(not(target_arch = "wasm32"))]
	Driver {
		raw: *mut GlowcapDriverLoop,
		context: Option<Rc<ContextInner>>,
		refusal_reported: bool,
		completion: Option<FailedDriverCompletion>,
	},
	#[cfg(test)]
	Test {
		owner: Option<tests::RetainedOwner>,
		attempts: Rc<std::cell::Cell<usize>>,
		completions: Rc<std::cell::Cell<usize>>,
		refusals_left: usize,
	},
}

#[cfg(not(target_arch = "wasm32"))]
struct FailedDriverCompletion {
	host: Rc<HostShared>,
	failure: Error,
}

// A refused native release still borrows the Rust owner. Thread exit cannot
// revoke that borrow or run async recovery. Keep unfinished owners alive for
// the process lifetime instead of dropping them with TLS. This key has no
// destructor, so releases from other TLS destructors can still be parked.
// Successful drains return the empty queue's allocation below.
thread_local! {
	static PENDING: RefCell<ManuallyDrop<VecDeque<PendingRelease>>> =
		const { RefCell::new(ManuallyDrop::new(VecDeque::new())) };
}

fn reclaim_empty_queue() {
	PENDING.with(|pending| {
		let mut pending = pending.borrow_mut();
		if pending.is_empty() {
			pending.shrink_to_fit();
		}
	});
}

fn record(context: Option<&Rc<ContextInner>>, layer: FailureLayer, operation: &str, error: &Error) {
	if let Some(context) = context {
		context.report_failure(layer, FailureScope::Context, 0, 0, operation, error);
	} else {
		crate::record_runtime_failure(layer, operation, error.clone());
	}
}

#[cfg(not(target_arch = "wasm32"))]
fn retain_driver_release_failure(primary: Error, outcome: Result<()>) -> Error {
	match outcome {
		Ok(()) => primary,
		Err(error) => primary.with_secondary(error),
	}
}

pub(crate) fn park_session(shared: Rc<SessionShared>) {
	PENDING.with(|pending| pending.borrow_mut().push_back(PendingRelease::Session(shared)));
}

pub(crate) fn park_host(raw: *mut ffi_host::GlowcapHost, context: Option<Rc<ContextInner>>, refusal_reported: bool) {
	PENDING.with(|pending| {
		pending.borrow_mut().push_back(PendingRelease::Host {
			raw,
			context,
			refusal_reported,
		})
	});
}

#[cfg(not(target_arch = "wasm32"))]
pub(crate) fn park_driver(raw: *mut GlowcapDriverLoop, context: Option<Rc<ContextInner>>, refusal_reported: bool) {
	PENDING.with(|pending| {
		pending.borrow_mut().push_back(PendingRelease::Driver {
			raw,
			context,
			refusal_reported,
			completion: None,
		})
	});
}

/// Retain a refused live-loop release together with the wrapper state that can
/// retire only after a later consuming attempt. The first failure is already
/// the Host close result; retries preserve it rather than reporting duplicates.
#[cfg(not(target_arch = "wasm32"))]
pub(crate) fn park_failed_driver(
	raw: *mut GlowcapDriverLoop,
	context: Option<Rc<ContextInner>>,
	host: Rc<HostShared>,
	failure: Error,
) {
	PENDING.with(|pending| {
		pending.borrow_mut().push_back(PendingRelease::Driver {
			raw,
			context,
			refusal_reported: true,
			completion: Some(FailedDriverCompletion { host, failure }),
		})
	});
}

#[cfg(not(target_arch = "wasm32"))]
pub(crate) fn discard_host_sessions(host: &Rc<HostShared>) {
	PENDING.with(|pending| {
		pending
			.borrow_mut()
			.retain(|item| !matches!(item, PendingRelease::Session(shared) if Rc::ptr_eq(&shared.host, host)))
	});
	reclaim_empty_queue();
}

pub(crate) fn drain_host_sessions(host: &Rc<HostShared>) -> Result<()> {
	loop {
		let parked = PENDING.with(|pending| {
			let mut pending = pending.borrow_mut();
			let index = pending
				.iter()
				.position(|item| matches!(item, PendingRelease::Session(shared) if Rc::ptr_eq(&shared.host, host)));
			index.and_then(|index| pending.remove(index))
		});
		let Some(PendingRelease::Session(shared)) = parked else {
			reclaim_empty_queue();
			return Ok(());
		};
		if let Err(error) = shared.finish_native_release() {
			park_session(shared);
			return Err(error);
		}
	}
}

/// Drain one claimed batch outside a hosted callback. Re-refusals stay owned
/// for the next boundary and therefore cannot spin this turn.
pub(crate) fn drain() {
	if crate::trampoline::inside_turn() {
		return;
	}
	let count = PENDING.with(|pending| pending.borrow().len());
	if count == 0 {
		return;
	}
	for _ in 0..count {
		let Some(item) = PENDING.with(|pending| pending.borrow_mut().pop_front()) else {
			break;
		};
		match item {
			#[cfg(feature = "loam")]
			PendingRelease::Loam(owner) => {
				if !owner.close_from_drop() {
					park_loam(owner);
				}
			}
			#[cfg(feature = "loam")]
			PendingRelease::LoamWork { owner, raw } => {
				if !crate::loam::work::finish_retired(&owner, raw) {
					park_loam_work(owner, raw);
				}
			}
			#[cfg(feature = "loam")]
			PendingRelease::LoamEffectExecution { owner, raw } => {
				if unsafe { crate::sys::loam::glowcap_loam_effect_execution_release(raw) } != sys::OK {
					park_loam_effect_execution(owner, raw);
				}
			}
			#[cfg(all(feature = "loam", target_arch = "wasm32"))]
			PendingRelease::BrowserLoamStore { backend, store } => backend.retire(store),
			#[cfg(all(feature = "loam", not(target_arch = "wasm32")))]
			PendingRelease::LoamStore(raw) => {
				let mut rc = unsafe { crate::sys::loam::glowcap_loam_lmdb_release(raw) };
				if rc == crate::sys::loam::GLOWCAP_LOAM_ERR_RECOVERY_REQUIRED {
					let recovered = unsafe { crate::sys::loam::glowcap_loam_lmdb_recover(raw) };
					if recovered == sys::OK || recovered == crate::sys::loam::GLOWCAP_LOAM_ERR_UNCHANGED {
						rc = unsafe { crate::sys::loam::glowcap_loam_lmdb_release(raw) };
					}
				}
				if rc != sys::OK {
					park_loam_store(raw);
				}
			}
			PendingRelease::Session(shared) => {
				if shared.finish_native_release().is_err() {
					park_session(shared);
				}
			}
			PendingRelease::Host {
				raw,
				context,
				mut refusal_reported,
			} => {
				crate::trace::detach_host(raw);
				let rc = unsafe { ffi_host::glowcap_host_release(raw) };
				if rc != sys::OK
					&& let Err(error) = check_host(rc)
					&& (crate::lifecycle::release_consumed(rc) || !refusal_reported)
				{
					record(
						context.as_ref(),
						FailureLayer::Binding,
						"host-finalizer.release",
						&error,
					);
					refusal_reported = true;
				}
				if !crate::lifecycle::release_consumed(rc) {
					PENDING.with(|pending| {
						pending.borrow_mut().push_back(PendingRelease::Host {
							raw,
							context,
							refusal_reported,
						})
					});
				}
			}
			#[cfg(not(target_arch = "wasm32"))]
			PendingRelease::Driver {
				raw,
				context,
				mut refusal_reported,
				completion,
			} => {
				let (rc, outcome) = crate::driver_failure::release(raw);
				let consumed = crate::lifecycle::release_consumed(rc);
				if let Err(error) = outcome.as_ref()
					&& (crate::lifecycle::release_consumed(rc) || !refusal_reported)
				{
					if completion.is_none() {
						record(
							context.as_ref(),
							FailureLayer::Driver,
							"driver-loop.finalizer.release",
							error,
						);
					}
					refusal_reported = true;
				}
				if !consumed {
					PENDING.with(|pending| {
						pending.borrow_mut().push_back(PendingRelease::Driver {
							raw,
							context,
							refusal_reported,
							completion,
						})
					});
				} else if let Some(completion) = completion {
					let terminal = retain_driver_release_failure(completion.failure, outcome);
					completion.host.finish_deferred_failed_loop_teardown(terminal);
				}
			}
			#[cfg(test)]
			PendingRelease::Test {
				owner,
				attempts,
				completions,
				refusals_left,
			} => {
				attempts.set(attempts.get() + 1);
				if refusals_left > 0 {
					PENDING.with(|pending| {
						pending.borrow_mut().push_back(PendingRelease::Test {
							owner,
							attempts,
							completions,
							refusals_left: refusals_left - 1,
						})
					});
				} else {
					completions.set(completions.get() + 1);
				}
			}
		}
	}
	reclaim_empty_queue();
}

#[cfg(test)]
pub(crate) fn pending_count() -> usize {
	PENDING.with(|pending| pending.borrow().len())
}

#[cfg(test)]
pub(crate) fn park_test_release(
	attempts: Rc<std::cell::Cell<usize>>,
	completions: Rc<std::cell::Cell<usize>>,
	refusals_left: usize,
) {
	PENDING.with(|pending| {
		pending.borrow_mut().push_back(PendingRelease::Test {
			owner: None,
			attempts,
			completions,
			refusals_left,
		})
	});
}

#[cfg(feature = "loam")]
pub(crate) fn park_loam(owner: Rc<crate::loam::AttachmentInner>) {
	PENDING.with(|pending| pending.borrow_mut().push_back(PendingRelease::Loam(owner)));
}
#[cfg(feature = "loam")]
pub(crate) fn park_loam_work(owner: Rc<crate::loam::AttachmentInner>, raw: *mut crate::sys::loam::GlowcapLoamWork) {
	PENDING.with(|pending| pending.borrow_mut().push_back(PendingRelease::LoamWork { owner, raw }));
}
#[cfg(feature = "loam")]
pub(crate) fn park_loam_effect_execution(
	owner: Rc<crate::loam::AttachmentInner>,
	raw: *mut crate::sys::loam::GlowcapLoamEffectExecution,
) {
	PENDING.with(|pending| {
		pending
			.borrow_mut()
			.push_back(PendingRelease::LoamEffectExecution { owner, raw })
	});
}

#[cfg(all(feature = "loam", not(target_arch = "wasm32")))]
pub(crate) fn park_loam_store(raw: *mut crate::sys::loam::GlowcapLoamLmdb) {
	PENDING.with(|pending| pending.borrow_mut().push_back(PendingRelease::LoamStore(raw)));
}

#[cfg(test)]
mod tests {
	use super::*;
	use std::sync::{
		Arc,
		atomic::{AtomicUsize, Ordering},
	};

	pub(super) struct RetainedOwner(Arc<AtomicUsize>);
	impl Drop for RetainedOwner {
		fn drop(&mut self) {
			self.0.fetch_add(1, Ordering::SeqCst);
		}
	}

	#[test]
	fn another_tls_destructor_can_park_a_refused_release() {
		struct LateRelease(Option<RetainedOwner>);
		impl Drop for LateRelease {
			fn drop(&mut self) {
				PENDING.with(|pending| {
					pending.borrow_mut().push_back(PendingRelease::Test {
						owner: self.0.take(),
						attempts: Rc::new(std::cell::Cell::new(0)),
						completions: Rc::new(std::cell::Cell::new(0)),
						refusals_left: 1,
					})
				});
			}
		}
		let released = Arc::new(AtomicUsize::new(0));
		let observed = released.clone();
		std::thread::spawn(move || {
			thread_local! {
				static LATE: RefCell<Option<LateRelease>> = const { RefCell::new(None) };
			}
			// Register this destructor before using the finalizer queue. A queue
			// with its own destructor would be unavailable when LATE drops.
			LATE.with(|late| *late.borrow_mut() = Some(LateRelease(Some(RetainedOwner(released)))));
			park_test_release(Rc::new(std::cell::Cell::new(0)), Rc::new(std::cell::Cell::new(0)), 0);
			drain();
		})
		.join()
		.unwrap();
		assert_eq!(observed.load(Ordering::SeqCst), 0);
	}

	#[test]
	fn thread_exit_preserves_owners_of_unfinished_releases() {
		for finish in [false, true] {
			let released = Arc::new(AtomicUsize::new(0));
			let observed = released.clone();
			std::thread::spawn(move || {
				PENDING.with(|pending| {
					pending.borrow_mut().push_back(PendingRelease::Test {
						owner: Some(RetainedOwner(released)),
						attempts: Rc::new(std::cell::Cell::new(0)),
						completions: Rc::new(std::cell::Cell::new(0)),
						refusals_left: 1,
					})
				});
				drain();
				assert_eq!(pending_count(), 1);
				if finish {
					drain();
					assert_eq!(pending_count(), 0);
					PENDING.with(|pending| assert_eq!(pending.borrow().capacity(), 0));
				}
			})
			.join()
			.unwrap();
			assert_eq!(observed.load(Ordering::SeqCst), usize::from(finish));
		}
	}

	#[test]
	fn one_boundary_claims_one_batch_and_a_refusal_waits_for_the_next() {
		let attempts = Rc::new(std::cell::Cell::new(0));
		let completions = Rc::new(std::cell::Cell::new(0));
		park_test_release(Rc::clone(&attempts), Rc::clone(&completions), 1);
		drain();
		assert_eq!(attempts.get(), 1);
		assert_eq!(completions.get(), 0);
		assert_eq!(pending_count(), 1);
		drain();
		assert_eq!(attempts.get(), 2);
		assert_eq!(completions.get(), 1);
		assert_eq!(pending_count(), 0);
		drain();
		assert_eq!(attempts.get(), 2);
		assert_eq!(completions.get(), 1);
	}

	#[test]
	fn consuming_release_failure_is_a_consequence_of_the_terminal_primary() {
		let primary = Error::with_detail(sys::ERR_INTERNAL, "background step failed".to_string());
		let release = Error::with_detail(sys::ERR_IO, "provider release failed".to_string());
		let terminal = retain_driver_release_failure(primary.clone(), Err(release.clone()));
		assert_eq!(terminal.code(), primary.code());
		assert_eq!(terminal.message(), primary.message());
		assert_eq!(terminal.secondary_error_count(), 1);
		assert_eq!(terminal.secondary_errors(), &[release]);
	}
}

#[cfg(all(feature = "loam", target_arch = "wasm32"))]
pub(crate) fn park_browser_loam_store(
	backend: crate::loam::browser::Storage,
	store: *mut crate::sys::loam::GlowcapLoamStore,
) {
	PENDING.with(|pending| {
		pending
			.borrow_mut()
			.push_back(PendingRelease::BrowserLoamStore { backend, store })
	});
}
