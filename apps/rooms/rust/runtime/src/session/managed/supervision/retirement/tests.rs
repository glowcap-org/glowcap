//! Retirement keeps the actual leave receiver across cancellation and late results.
use super::*;
use glowcap::PendingWork;
use std::{future::poll_fn, rc::Rc, task::Poll};

async fn pending(work: impl Future<Output = Result<()>>) {
	tokio::pin!(work);
	poll_fn(|cx| {
		assert!(work.as_mut().poll(cx).is_pending());
		Poll::Ready(())
	})
	.await;
}

#[tokio::test]
async fn late_seat_and_interrupted_leave_keep_the_exact_receiver() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let host = Host::from_seed([124; 32]).unwrap();
			let calls = Rc::new(Cell::new(0));
			let answer = Rc::new(RefCell::new(None));
			let seat = host
				.spawn({
					let host = host.clone();
					let calls = calls.clone();
					let answer = answer.clone();
					move |verb, args| {
						assert_eq!(verb, "leave");
						assert!(args.is_empty());
						calls.set(calls.get() + 1);
						*answer.borrow_mut() = Some(host.defer_turn().unwrap());
						Ok(Argument::Void)
					}
				})
				.unwrap();
			let owner = Owner::new(host.clone());
			owner.begin();
			pending(owner.close()).await;
			assert_eq!(calls.get(), 0, "pending admission cannot guess a target");
			owner.ready(seat.clone()).unwrap();
			pending(owner.close()).await;
			assert_eq!(calls.get(), 1);
			pending(owner.close()).await;
			assert_eq!(calls.get(), 1, "interrupted wait cannot send another leave");
			answer.borrow_mut().as_mut().unwrap().fulfill(&Argument::Void).unwrap();
			owner.close().await.unwrap();
			owner.close().await.unwrap();
			assert_eq!(calls.get(), 1);
			drop((answer, owner, seat));
			host.close(PendingWork::Cancel).await.unwrap();
		})
		.await;
}

#[tokio::test]
async fn uncertain_admission_refuses_retirement_and_preserves_custody() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let host = Host::from_seed([125; 32]).unwrap();
			let owner = Owner::new(host.clone());
			owner.begin();
			owner.unknown(loam::refusal("original subscription is unknown"));
			for _ in 0..2 {
				assert_eq!(
					owner.close().await.unwrap_err().message(),
					Some("original subscription is unknown")
				);
			}
			assert!(matches!(*owner.outcome.borrow(), Outcome::Unknown(_)));
			drop(owner);
			host.close(PendingWork::Cancel).await.unwrap();
		})
		.await;
}
