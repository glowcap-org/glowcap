//! Reservation lifetime, fairness, and registration retirement without transport timing.
use super::*;
use rooms_application::{directory::registration::NicknameAllocation, server::directory::Register};

fn id(n: u64) -> Id {
	Id::parse(&format!("{n:08x}-0000-4000-8000-000000000000")).unwrap()
}

fn register(policy: &mut Policy, inbox: &Ref, connection: u64, generation: u64) {
	policy
		.register(
			connection,
			Register {
				nick: format!("member{connection}"),
				allocation: NicknameAllocation::Exact,
				locator: "ocapn://fixture.tcp".into(),
				own_locator: true,
				host_key: None,
				inbox: inbox.clone(),
				voucher: None,
				claimant: None,
			},
			id(generation),
			0,
		)
		.unwrap();
}

#[tokio::test]
async fn reservations_bound_each_caller_and_survive_notification_until_consumed() {
	rooms_testing::local_set::run(async {
		let context = glowcap::Context::new().unwrap();
		let host = glowcap::Host::new_in(&context, Default::default()).unwrap();
		let inbox = host.spawn(|_, _| Ok(Argument::Void)).unwrap();
		let mut policy = Policy::default();
		for connection in 1..=10 {
			register(&mut policy, &inbox, connection, connection);
		}
		let pending = Pending::default();
		let mut held = Vec::new();
		for caller in 1..=8 {
			for opening in 0..MAX_PER_CALLER {
				held.push(pending.park(&policy, caller, id(10), &opening.to_string(), 10).unwrap());
			}
			assert!(pending.park(&policy, caller, id(10), "overflow", 10).is_err());
		}
		assert_eq!(held.len(), introduction::MAX_OUTSTANDING);
		assert!(pending.park(&policy, 9, id(10), "other", 10).is_err());
		pending.offered(&InboxOffered {
			caller: 1,
			target: id(10),
			opening: "0".into(),
		});
		assert_eq!(held[0].receive.try_recv().unwrap(), Ok(()));
		assert!(
			pending.unparked(1, &id(10), "0").is_err(),
			"a signaled offer remains reserved"
		);
		assert!(pending.park(&policy, 9, id(10), "other", 10).is_err());
		drop(held.remove(0));
		assert!(pending.unparked(1, &id(10), "0").is_ok());
		let replacement = pending.park(&policy, 9, id(10), "other", 10).unwrap();
		drop((held, replacement));
		assert!(
			pending.entries.borrow().is_empty(),
			"cancellation returns every reservation"
		);
		drop((policy, inbox));
		host.close(glowcap::PendingWork::Cancel).await.unwrap();
	})
	.await;
}

#[tokio::test]
async fn original_registrations_own_waiting_introductions() {
	rooms_testing::local_set::run(async {
		let context = glowcap::Context::new().unwrap();
		let host = glowcap::Host::new_in(&context, Default::default()).unwrap();
		let inbox = host.spawn(|_, _| Ok(Argument::Void)).unwrap();
		let mut policy = Policy::default();
		register(&mut policy, &inbox, 1, 1);
		register(&mut policy, &inbox, 2, 2);
		let pending = Pending::default();
		let mut waiting = pending.park(&policy, 1, id(2), "opening", 2).unwrap();
		// The same connection's new name generation cannot inherit this request.
		policy.connection_closed(2);
		register(&mut policy, &inbox, 2, 3);
		pending.revalidate(&policy);
		assert_eq!(waiting.receive.try_recv().unwrap(), Err(ended()));
		drop(waiting);
		// The caller's own name ending is its own refusal, not the member's.
		let mut waiting = pending.park(&policy, 1, id(3), "opening", 2).unwrap();
		policy.connection_closed(1);
		register(&mut policy, &inbox, 1, 4);
		pending.revalidate(&policy);
		assert_eq!(waiting.receive.try_recv().unwrap(), Err(caller_ended()));
		drop(waiting);
		let mut waiting = pending.park(&policy, 1, id(3), "opening", 2).unwrap();
		pending.closed(2);
		assert_eq!(waiting.receive.try_recv().unwrap(), Err(ended()));
		drop(waiting);
		let mut waiting = pending.park(&policy, 1, id(3), "opening", 2).unwrap();
		pending.closed(1);
		assert_eq!(waiting.receive.try_recv().unwrap(), Err(caller_ended()));
		drop((waiting, policy, inbox));
		host.close(glowcap::PendingWork::Cancel).await.unwrap();
	})
	.await;
}

/// The caller's wait was promised from when the server held the introduction.
#[tokio::test(start_paused = true)]
async fn a_held_introduction_times_out_from_when_it_was_held() {
	rooms_testing::local_set::run(async {
		let context = glowcap::Context::new().unwrap();
		let host = glowcap::Host::new_in(&context, Default::default()).unwrap();
		let inbox = host.spawn(|_, _| Ok(Argument::Void)).unwrap();
		let mut policy = Policy::default();
		for connection in 1..=2 {
			register(&mut policy, &inbox, connection, connection);
		}
		let pending = Pending::default();
		let wait = Duration::from_millis(introduction::WAIT_MS);
		let mut waiting = pending.park(&policy, 1, id(2), "opening", 2).unwrap();
		tokio::time::advance(wait / 2).await;
		let started = Instant::now();
		let refused = waiting.offer(std::future::pending()).await.unwrap_err();
		assert_eq!(
			rooms_application::failure::Failure::parse(&refused).map(|failure| failure.code),
			Some(FailureCode::IntroductionTimedOut),
			"{refused}"
		);
		assert_eq!(started.elapsed(), wait / 2);
		drop((waiting, policy, inbox));
		host.close(glowcap::PendingWork::Cancel).await.unwrap();
	})
	.await;
}
