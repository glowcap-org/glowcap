use std::sync::{LockResult, Mutex, MutexGuard};

use crate::{sys, Error};

/// No iroh mutex protects an application invariant: critical sections only
/// move owned task handles, readiness flags, wakers, and channel endpoints.
/// If a panic poisons one, the contained values remain valid. Recover the
/// guard, clear the sticky poison bit, and publish the containment event rather
/// than turning every later library call into another process panic.
pub(super) fn lock_iroh<'a, T>(mutex: &'a Mutex<T>, source: &'static str) -> MutexGuard<'a, T> {
	recover_iroh_lock(mutex, mutex.lock(), source)
}

fn recover_iroh_lock<'a, T>(
	mutex: &'a Mutex<T>,
	result: LockResult<MutexGuard<'a, T>>,
	source: &'static str,
) -> MutexGuard<'a, T> {
	match result {
		Ok(guard) => guard,
		Err(poisoned) => {
			let guard = poisoned.into_inner();
			mutex.clear_poison();
			crate::record_runtime_failure(
				crate::FailureLayer::Transport,
				source,
				Error::with_detail(sys::ERR_INTERNAL, "iroh synchronization state was poisoned".to_string()),
			);
			guard
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use std::sync::Mutex;

	#[test]
	fn poisoned_internal_mutex_is_recovered_and_diagnosed() {
		let _serial = crate::RUNTIME_FAILURE_TEST_LOCK
			.lock()
			.unwrap_or_else(std::sync::PoisonError::into_inner);
		crate::take_runtime_failures();
		let value = Mutex::new(7usize);
		let guard = value.lock().unwrap();
		let recovered = recover_iroh_lock(&value, Err(std::sync::PoisonError::new(guard)), "iroh-test-lock-poison");
		assert_eq!(*recovered, 7);
		drop(recovered);
		assert!(!value.is_poisoned());
		let diagnostics = crate::take_runtime_failures();
		assert!(diagnostics.iter().any(|failure| {
			failure.operation == "iroh-test-lock-poison"
				&& failure.primary_message == "iroh synchronization state was poisoned"
		}));
	}
}
