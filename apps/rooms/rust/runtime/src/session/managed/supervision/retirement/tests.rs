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
	rooms_testing::local_set::run(async {
		let host = Host::from_seed([124; 32]).unwrap();
		let calls = Rc::new(Cell::new(0));
		let answer = Rc::new(RefCell::new(None));
		let seat = host
			.spawn({
				let host = host.clone();
				let calls = calls.clone();
				let answer = answer.clone();
				move |verb, args| {
					assert_eq!(verb, Some("leave"));
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
	rooms_testing::local_set::run(async {
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

#[tokio::test]
async fn a_retired_job_forfeits_only_a_pending_admission_and_wakes_its_close() {
	rooms_testing::local_set::run(async {
		let host = Host::from_seed([126; 32]).unwrap();
		let calls = Rc::new(Cell::new(0));
		let seat = host
			.spawn({
				let calls = calls.clone();
				move |_, _| {
					calls.set(calls.get() + 1);
					Ok(Argument::Void)
				}
			})
			.unwrap();
		// A job retired before it dispatched leaves no endpoint, so the close
		// waiting on its admission returns at once and sends no leave.
		let owner = Owner::new(host.clone());
		owner.begin();
		let close = owner.close();
		tokio::pin!(close);
		poll_fn(|cx| {
			assert!(
				close.as_mut().poll(cx).is_pending(),
				"a pending admission holds its close"
			);
			owner.forfeit(None);
			assert!(
				matches!(close.as_mut().poll(cx), Poll::Ready(Ok(()))),
				"the forfeit wakes the close, which finds no endpoint"
			);
			Poll::Ready(())
		})
		.await;
		assert!(matches!(*owner.outcome.borrow(), Outcome::Absent));
		// A job retired after it dispatched may have left an endpoint, so the
		// membership keeps its pause's cause and every close refuses with it.
		let paused = Owner::new(host.clone());
		paused.begin();
		paused.forfeit(Some(crate::session::managed::executor::paused(
			"effect observation deadline expired",
		)));
		for _ in 0..2 {
			assert_eq!(
				paused.close().await.unwrap_err().message(),
				Some("effect observation deadline expired")
			);
		}
		assert!(matches!(*paused.outcome.borrow(), Outcome::Unknown(_)));
		// An outcome the job already reported stays, and its close leaves.
		let seated = Owner::new(host.clone());
		seated.begin();
		seated.ready(seat.clone()).unwrap();
		seated.forfeit(Some(loam::refusal("late retirement")));
		assert!(matches!(*seated.outcome.borrow(), Outcome::Ready(_)));
		seated.close().await.unwrap();
		assert_eq!(calls.get(), 1, "the reported seat is the one left");
		drop((paused, seated, seat));
		host.close(PendingWork::Cancel).await.unwrap();
	})
	.await;
}
