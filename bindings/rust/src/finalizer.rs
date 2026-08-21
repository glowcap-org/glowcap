//! Failure-cold ownership for native releases refused from Rust `Drop` paths.
//!
//! One safe boundary claims a finite queue prefix. A refusal requeues its
//! owner for the next boundary rather than spinning; native allocation policy
//! stays retained until the consuming release call.

use std::cell::RefCell;
use std::collections::VecDeque;
use std::rc::Rc;

use crate::context::ContextInner;
use crate::host::{check_host, HostShared};
use crate::session_shared::SessionShared;
use crate::sys::{self, driver::PancakeDriverLoop, host as ffi_host};
use crate::{Error, FailureLayer, FailureScope, Result};

enum PendingRelease {
	Session(Rc<SessionShared>),
	Host {
		raw: *mut ffi_host::PancakeHost,
		context: Option<Rc<ContextInner>>,
		refusal_reported: bool,
	},
	Driver {
		raw: *mut PancakeDriverLoop,
		context: Option<Rc<ContextInner>>,
		refusal_reported: bool,
		completion: Option<FailedDriverCompletion>,
	},
	#[cfg(test)]
	Test {
		attempts: Rc<std::cell::Cell<usize>>,
		completions: Rc<std::cell::Cell<usize>>,
		refusals_left: usize,
	},
}

struct FailedDriverCompletion {
	host: Rc<HostShared>,
	failure: Error,
}

thread_local! {
	static PENDING: RefCell<VecDeque<PendingRelease>> = const { RefCell::new(VecDeque::new()) };
}

fn record(context: Option<&Rc<ContextInner>>, layer: FailureLayer, operation: &str, error: &Error) {
	if let Some(context) = context {
		context.report_failure(layer, FailureScope::Context, 0, 0, operation, error);
	} else {
		crate::record_runtime_failure(layer, operation, error.clone());
	}
}

fn retain_driver_release_failure(primary: Error, outcome: Result<()>) -> Error {
	match outcome {
		Ok(()) => primary,
		Err(error) => primary.with_secondary(error),
	}
}

pub(crate) fn park_session(shared: Rc<SessionShared>) {
	PENDING.with(|pending| pending.borrow_mut().push_back(PendingRelease::Session(shared)));
}

pub(crate) fn park_host(raw: *mut ffi_host::PancakeHost, context: Option<Rc<ContextInner>>, refusal_reported: bool) {
	PENDING.with(|pending| {
		pending.borrow_mut().push_back(PendingRelease::Host {
			raw,
			context,
			refusal_reported,
		})
	});
}

pub(crate) fn park_driver(raw: *mut PancakeDriverLoop, context: Option<Rc<ContextInner>>, refusal_reported: bool) {
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
pub(crate) fn park_failed_driver(
	raw: *mut PancakeDriverLoop,
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

pub(crate) fn discard_host_sessions(host: &Rc<HostShared>) {
	PENDING.with(|pending| {
		pending
			.borrow_mut()
			.retain(|item| !matches!(item, PendingRelease::Session(shared) if Rc::ptr_eq(&shared.host, host)))
	});
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
	for _ in 0..count {
		let Some(item) = PENDING.with(|pending| pending.borrow_mut().pop_front()) else {
			return;
		};
		match item {
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
				let rc = unsafe { ffi_host::pancake_host_release(raw) };
				if rc != sys::OK {
					if let Err(error) = check_host(rc) {
						if crate::lifecycle::release_consumed(rc) || !refusal_reported {
							record(
								context.as_ref(),
								FailureLayer::Binding,
								"host-finalizer.release",
								&error,
							);
							refusal_reported = true;
						}
					}
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
			PendingRelease::Driver {
				raw,
				context,
				mut refusal_reported,
				completion,
			} => {
				let (rc, outcome) = crate::driver_failure::release(raw);
				let consumed = crate::lifecycle::release_consumed(rc);
				if let Err(error) = outcome.as_ref() {
					if crate::lifecycle::release_consumed(rc) || !refusal_reported {
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
				attempts,
				completions,
				refusals_left,
			} => {
				attempts.set(attempts.get() + 1);
				if refusals_left > 0 {
					PENDING.with(|pending| {
						pending.borrow_mut().push_back(PendingRelease::Test {
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
			attempts,
			completions,
			refusals_left,
		})
	});
}

#[cfg(test)]
mod tests {
	use super::*;

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
