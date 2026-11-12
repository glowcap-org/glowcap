//! A journal whose clock cannot date an event accepts nothing.
use super::*;
use std::{future::Future, num::NonZeroU64, pin::Pin};

#[derive(Clone)]
struct Undated;
impl Tasks for Undated {
	type Task = Pin<Box<dyn Future<Output = ()>>>;
	fn spawn(&self, work: impl Future<Output = ()> + 'static) -> Self::Task {
		Box::pin(work)
	}
}
impl Deadline for Undated {
	fn monotonic_millis(&self) -> u64 {
		0
	}
	async fn within<T>(&self, _: u64, work: impl Future<Output = T>) -> Option<T> {
		Some(work.await)
	}
}
impl WallClock for Undated {
	fn unix_millis(&self) -> core::result::Result<u64, crate::wall_clock::Error> {
		Err(crate::wall_clock::Error::BeforeEpoch)
	}
}

#[tokio::test]
async fn an_event_the_clock_cannot_date_is_refused_without_effect() {
	rooms_testing::local_set::run(async {
		let host = glowcap::Host::from_seed([223; 32]).unwrap();
		let source = host.spawn(|_, _| Ok(glowcap::Argument::Void)).unwrap();
		let activity = Rc::new(Activity::new(host, Undated));
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
