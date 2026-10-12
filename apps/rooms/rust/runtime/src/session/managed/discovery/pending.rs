//! A deadline reports uncertainty while the original request remains polled.
use super::*;

pub(super) async fn wait<P: Deadline>(
	platform: &P,
	pending: &mut Pending,
	signals: &mut supervision::Signals,
	cleanup: bool,
) -> Result<Argument> {
	signals.stopping.borrow_and_update();
	signals.retrying.borrow_and_update();
	loop {
		if let Some(result) = platform.within(WAIT_MS, pending.as_mut()).await {
			return result;
		}
		let failure = loam::refusal(if cleanup {
			"directory cancellation is still unresolved"
		} else {
			"directory discovery admission is still unresolved"
		});
		if !cleanup {
			signals.ready.send_replace(Some(Err(failure.clone())));
		}
		if cleanup || *signals.stopping.borrow() {
			signals.finished.send_replace(Some(Err(failure.clone())));
		}
		loop {
			tokio::select! {
				result = pending.as_mut() => return result,
				_ = signals.retrying.changed() => break,
				_ = signals.stopping.changed() => {
					if cleanup || *signals.stopping.borrow_and_update() {
						signals.finished.send_replace(Some(Err(failure.clone())));
					}
				},
			}
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use tokio::sync::watch;
	struct Expired;
	impl Deadline for Expired {
		fn monotonic_millis(&self) -> u64 {
			0
		}
		async fn within<T>(&self, _: u64, _: impl Future<Output = T>) -> Option<T> {
			None
		}
	}
	#[tokio::test]
	async fn late_outcome_wakes_dropped_view_without_retrying_or_resending() {
		let (stop, stopping) = watch::channel(false);
		let (_retry, retrying) = watch::channel(0);
		let (ready, _) = watch::channel(None);
		let (finished, _) = watch::channel(None);
		let mut ended = finished.subscribe();
		let mut signals = supervision::Signals {
			ready,
			stopping,
			retrying,
			finished,
		};
		let (answer, reply) = oneshot::channel();
		let mut pending: Pending = Box::pin(async move { reply.await.unwrap() });
		let result = wait(&Expired, &mut pending, &mut signals, false);
		tokio::pin!(result);
		tokio::select! {
			_ = &mut result => panic!("unknown admission was discarded"),
			_ = async {
				stop.send_replace(true);
				ended.changed().await.unwrap();
				assert!(ended.borrow().as_ref().unwrap().is_err());
				answer.send(Ok(Argument::Void)).unwrap();
			} => {},
		}
		assert_eq!(result.await.unwrap(), Argument::Void);
	}
}
