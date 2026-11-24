//! The wait before the next try after a failure, doubling up to a ceiling.
use std::time::Duration;

/// The longest wait between tries after a failure that may clear on its own.
pub const STANDARD_CEILING: Duration = Duration::from_secs(60);
/// The longest wait between tries for access that only a person changes.
pub const SLOW_CEILING: Duration = Duration::from_secs(300);

pub struct Backoff {
	first: Duration,
	ceiling: Duration,
	next: Duration,
}

impl Backoff {
	pub fn new(first: Duration, ceiling: Duration) -> Self {
		Self {
			first,
			ceiling,
			next: first,
		}
	}

	/// The session's standard: one second up to one minute.
	pub fn standard() -> Self {
		Self::new(Duration::from_secs(1), STANDARD_CEILING)
	}

	/// For access that is paused or revoked (`env::access_of`), which a person
	/// has to change: one second up to five minutes.
	pub fn slow() -> Self {
		Self::new(Duration::from_secs(1), SLOW_CEILING)
	}

	pub fn next(&mut self) -> Duration {
		let wait = self.next;
		self.next = (self.next * 2).min(self.ceiling);
		wait
	}

	pub fn reset(&mut self) {
		self.next = self.first;
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn waits_double_to_the_ceiling_and_reset_on_success() {
		let mut backoff = Backoff::standard();
		let waits: Vec<u64> = (0..8).map(|_| backoff.next().as_secs()).collect();
		assert_eq!(waits, [1, 2, 4, 8, 16, 32, 60, 60]);
		backoff.reset();
		assert_eq!(backoff.next().as_secs(), 1);
		let mut slow = Backoff::slow();
		assert_eq!((0..12).map(|_| slow.next().as_secs()).last(), Some(300));
	}
}
