use super::*;
use crate::session_runtime::handed_rooms::{ACCEPTANCE_BYTES, ACCEPTANCE_LIMIT, OBSERVER_LIMIT};

#[tokio::test]
async fn room_acceptance_custody_counts_work_and_observers_through_completion() {
	deadline(async {
		let harness = Harness::new("handed-work-custody").await;
		let mut source = Source::new(&harness.offers[0]);
		let mut ids = Vec::new();
		for index in 0..handoff::LIMIT {
			ids.push(harness.hand(0, &source, &format!("room-{index}")).await);
		}
		let base = harness.revision();
		let mut observations = Vec::new();
		for (index, id) in ids.iter().enumerate().take(ACCEPTANCE_LIMIT) {
			observations.push(
				harness
					.rooms
					.accept(
						text(&format!("accept-{index}")),
						base,
						id.clone(),
						text(&format!("destination-{index}")),
					)
					.unwrap(),
			);
		}
		assert!(harness
			.rooms
			.accept(text("overflow"), base, ids[0].clone(), text("overflow"))
			.is_err());
		for _ in ACCEPTANCE_LIMIT..OBSERVER_LIMIT {
			observations.push(
				harness
					.rooms
					.accept(text("accept-0"), base, ids[0].clone(), text("destination-0"))
					.unwrap(),
			);
		}
		assert!(harness
			.rooms
			.accept(text("accept-0"), base, ids[0].clone(), text("destination-0"))
			.is_err());
		drop(observations);
		assert!(
			harness
				.rooms
				.accept(text("overflow"), base, ids[0].clone(), text("overflow"))
				.is_err(),
			"discarded observations cannot refund owned wire work"
		);
		let mut answers = Vec::new();
		for _ in 0..ACCEPTANCE_LIMIT {
			answers.push(source.answers.recv().await.unwrap());
		}
		assert_eq!(source.calls.get(), ACCEPTANCE_LIMIT);
		let repeated = harness
			.rooms
			.accept(text("accept-0"), base, ids[0].clone(), text("destination-0"))
			.unwrap();
		harness.rooms.close().await.unwrap();
		assert!(repeated.wait().await.is_err());
		drop((answers, source));
		harness.close().await;
	})
	.await;
}

#[tokio::test]
async fn room_acceptance_charges_retained_capacity_and_reports_aborted_worker() {
	deadline(async {
		let harness = Harness::new("handed-aborted").await;
		let mut source = Source::new(&harness.offers[0]);
		let id = harness.hand(0, &source, "private").await;
		let mut large = String::with_capacity(ACCEPTANCE_BYTES / 2);
		large.push_str("destination");
		let pending = harness
			.rooms
			.accept(
				text("large"),
				harness.revision(),
				id.clone(),
				Id::new(large.into()).unwrap(),
			)
			.unwrap();
		let mut second = String::with_capacity(ACCEPTANCE_BYTES / 2);
		second.push_str("other");
		assert!(harness
			.rooms
			.accept(
				text("full"),
				harness.revision(),
				id.clone(),
				Id::new(second.into()).unwrap()
			)
			.is_err());
		let answer = source.answers.recv().await.unwrap();
		harness.worker.abort();
		let Harness {
			fixture,
			rooms,
			worker,
			dispatch,
			dispatch_worker,
			offers,
			_contexts,
			_outcomes,
		} = harness;
		assert!(worker.await.unwrap_err().is_cancelled());
		assert!(pending
			.wait()
			.await
			.unwrap_err()
			.contains("without observing completion"));
		assert!(
			rooms.close().await.is_err(),
			"aborting the worker cannot claim observed shutdown"
		);
		assert_eq!(rooms.read(|rows| rows.len()), 0);
		assert!(
			offers[1].session.is_open(),
			"handoff retirement does not close a sibling session"
		);
		drop((answer, source, rooms, offers, _contexts));
		// The dispatcher retains its outcome consumer through actual shutdown.
		tokio::task::yield_now().await;
		dispatch.close().await.unwrap();
		dispatch_worker.await.unwrap().unwrap();
		drop(_outcomes);
		fixture.close().await;
	})
	.await;
}
