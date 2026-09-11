//! A channel's physical retirement precedes its Session release and belongs to
//! the Host's existing owned-task barrier. A cancelled observer cannot cancel it.
use super::*;

impl SessionShared {
	pub(super) fn retire_channel(self: &Rc<Self>) -> Result<bool> {
		if self.channel_close_started.get() {
			return Ok(false);
		}
		if self.channel_close.borrow().is_none() {
			return Ok(true);
		}
		let registration = self.host.start_owned_task()?;
		let shared = Rc::clone(self);
		// Take the resource inside the admitted task. If spawn is refused during
		// executor teardown, the Session/finalizer still retains its close owner.
		let task = crate::host::try_spawn_local_handle(async move {
			let _registration = registration;
			let mut close = shared
				.channel_close
				.borrow_mut()
				.take()
				.expect("one channel close owner");
			let outcome = std::future::poll_fn(|cx| {
				match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| close.poll_close(cx))) {
					Ok(result) => result,
					Err(payload) => std::task::Poll::Ready(Err(std::io::Error::other(format!(
						"channel close callback panicked: {}",
						crate::panic_message(payload.as_ref())
					)))),
				}
			})
			.await;
			drop(close);
			shared.channel_close_started.set(false);
			if let Err(error) = outcome {
				let error = io_err(error);
				shared.record_wire_failure(error.clone());
				shared.host.record_retirement_failure(error);
			}
			shared.close_transport();
			shared.host.note_close_activity();
		});
		if task.is_none() {
			return Err(Error::with_detail(
				sys::ERR_INTERNAL,
				"channel retirement requires a running LocalSet".into(),
			));
		}
		self.channel_close_started.set(true);
		Ok(false)
	}
}
