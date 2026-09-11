//! Monotonic scheduling supplied by the platform executor.
use std::{future::Future, ops::Add, time::Duration};

pub trait Clock {
	type Instant: Copy + Ord + Add<Duration, Output = Self::Instant>;
	fn now(&self) -> Self::Instant;
	fn sleep_until(&self, at: Self::Instant) -> impl Future<Output = ()>;
}
