//! Wrapper retirement after the native driver consumes its Host.

use super::*;

impl HostShared {
	/// Finish the wrapper half after the native loop has reached its close
	/// barrier and projected every committed event. The native Host itself dies
	/// with `glowcap_driver_release`, never through `glowcap_host_release`.
	pub(crate) fn finish_loop_teardown(self: &Rc<HostShared>, close_code: i32) {
		self.finish_loop_teardown_with(CloseBarrierState::Complete(close_code), None);
	}

	/// The same ownership retirement when the loop terminated because of a
	/// background failure. Native state is still fully released, while every
	/// Host close observer receives the exact first cause.
	pub(crate) fn finish_failed_loop_teardown(self: &Rc<HostShared>, error: Error) {
		self.finish_loop_teardown_with(CloseBarrierState::Failed, Some(error));
	}

	/// Retire wrapper state after a refused loop release was transferred to the
	/// recurring finalizer owner and a later attempt consumed native ownership.
	/// The Host may already have published the exact failure to close waiters;
	/// consumption still has to clear every now-stale native-facing shell.
	pub(crate) fn finish_deferred_failed_loop_teardown(self: &Rc<HostShared>, error: Error) {
		if !self.raw.get().is_null() {
			self.retire_loop_wrapper();
		}
		*self.close_failure.borrow_mut() = Some(error);
		self.close_barrier.set(CloseBarrierState::Failed);
		self.release_notify.notify_waiters();
	}

	fn finish_loop_teardown_with(self: &Rc<HostShared>, terminal: CloseBarrierState, failure: Option<Error>) {
		if matches!(
			self.close_barrier.get(),
			CloseBarrierState::Complete(_) | CloseBarrierState::Failed
		) {
			return;
		}
		self.close_barrier.set(CloseBarrierState::Running);
		self.retire_loop_wrapper();
		if let Some(error) = failure {
			*self.close_failure.borrow_mut() = Some(error);
		}
		self.close_barrier.set(terminal);
		self.release_notify.notify_waiters();
	}

	fn retire_loop_wrapper(self: &Rc<Self>) {
		let sessions: Vec<_> = self.sessions.borrow_mut().drain().map(|(_, session)| session).collect();
		for session in sessions {
			session.commit_native_release();
		}
		crate::finalizer::discard_host_sessions(self);
		debug_assert!(self.vows.only_settled());
		let raw = self.raw.replace(core::ptr::null_mut());
		crate::gc::retire(self);
		if !raw.is_null() {
			crate::trace::detach_host(raw);
		}
		self.vows.clear();
		// The loop's release runs every ctx-free callback; these maps hold only
		// non-owning pointers and must not serve stale lookups meanwhile.
		self.hosted.borrow_mut().clear();
		self.giftables.borrow_mut().clear();
	}
}
