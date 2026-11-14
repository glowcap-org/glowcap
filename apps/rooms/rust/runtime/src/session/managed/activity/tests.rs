//! A journal whose clock cannot date an event accepts nothing, and a search
//! by id stays exact once old entries have left the front.
use super::*;
use std::{future::Future, num::NonZeroU64, pin::Pin};

#[derive(Clone)]
struct Fixed(Option<u64>);
impl Tasks for Fixed {
	type Task = Pin<Box<dyn Future<Output = ()>>>;
	fn spawn(&self, work: impl Future<Output = ()> + 'static) -> Self::Task {
		Box::pin(work)
	}
}
impl Deadline for Fixed {
	fn monotonic_millis(&self) -> u64 {
		0
	}
	async fn within<T>(&self, _: u64, work: impl Future<Output = T>) -> Option<T> {
		Some(work.await)
	}
}
impl WallClock for Fixed {
	fn unix_millis(&self) -> core::result::Result<u64, crate::wall_clock::Error> {
		self.0.ok_or(crate::wall_clock::Error::BeforeEpoch)
	}
}

#[tokio::test]
async fn an_event_the_clock_cannot_date_is_refused_without_effect() {
	rooms_testing::local_set::run(async {
		let host = glowcap::Host::from_seed([223; 32]).unwrap();
		let source = host.spawn(|_, _| Ok(glowcap::Argument::Void)).unwrap();
		let activity = Rc::new(Activity::new(host, Fixed(None)));
		let archive = custody::FieldKey::new(NonZeroU64::new(1).unwrap(), NonZeroU64::new(1).unwrap());
		let refused = activity.archive_ended(source, archive).unwrap_err().to_string();
		let cause = crate::wall_clock::Error::BeforeEpoch.to_string();
		assert!(refused.contains(&cause), "{refused}");
		assert_eq!(activity.cursor(), 0, "a refused event takes no place in the journal");
		assert_eq!(activity.bytes.get(), 0, "a refused event charges nothing");
		assert!(activity.entries.borrow().is_empty());
	})
	.await;
}

#[tokio::test]
async fn a_search_by_id_is_exact_after_the_front_has_been_popped() {
	rooms_testing::local_set::run(async {
		let host = glowcap::Host::from_seed([224; 32]).unwrap();
		let source = host.spawn(|_, _| Ok(glowcap::Argument::Void)).unwrap();
		let activity = Rc::new(Activity::new(host, Fixed(Some(1))));
		let archive = custody::FieldKey::new(NonZeroU64::new(1).unwrap(), NonZeroU64::new(1).unwrap());
		for _ in 0..6 {
			activity.archive_ended(source.clone(), archive).unwrap();
		}
		{
			let mut entries = activity.entries.borrow_mut();
			entries.pop_front();
			entries.pop_front();
		}
		let entries = activity.entries.borrow();
		let after = |cursor| first_after(&entries, cursor).map(|entry| entry.id);
		assert_eq!(
			[0, 2, 3, 5, 6, 9].map(after),
			[Some(3), Some(3), Some(4), Some(6), None, None],
			"the first entry past a cursor is the same whether the cursor sits before the front, on it, or at the end"
		);
		let by_id = |id| with_id(&entries, id).map(|entry| entry.id);
		assert_eq!(
			[0, 1, 2, 3, 6, 7].map(by_id),
			[None, None, None, Some(3), Some(6), None],
			"an id that left the front or was never assigned finds nothing"
		);
		drop(entries);
		assert!(activity.event(4).is_ok());
		assert!(activity.event(2).is_err());
		assert!(activity.file(2, 0).is_err());
	})
	.await;
}
