//! A bucket retains debt in thousandths of a token-minute. Refill saturates
//! before multiplication can overflow. Refusal does not debit the bucket.
use super::{Class, Refusal};
const MINUTE_MS: u64 = 60_000;
#[derive(Clone, Copy, Debug)]
pub struct Rate {
	burst: u32,
	per_minute: u32,
}
impl Rate {
	pub const fn new(burst: u32, per_minute: u32) -> Self {
		assert!(burst != 0 && per_minute != 0);
		Self { burst, per_minute }
	}
	pub const fn burst(self) -> u32 {
		self.burst
	}
	pub const fn per_minute(self) -> u32 {
		self.per_minute
	}
	pub fn scaled(self, scale: u32) -> Option<Self> {
		if scale == 0 {
			return None;
		}
		Some(Self::new(
			self.burst.checked_mul(scale)?,
			self.per_minute.checked_mul(scale)?,
		))
	}
}
#[derive(Clone, Copy, Debug, Default)]
pub(super) struct Bucket {
	debt: u64,
	at: u64,
}
impl Bucket {
	fn remaining(self, rate: Rate, now: u64) -> u64 {
		self.debt
			.saturating_sub(now.saturating_sub(self.at).saturating_mul(u64::from(rate.per_minute)))
	}
	pub fn restored(self, rate: Rate, now: u64) -> bool {
		self.remaining(rate, now) == 0
	}
	pub fn check(self, rate: Rate, amount: u32, now: u64, class: Class) -> Result<(), Refusal> {
		if amount > rate.burst {
			return Err(Refusal::TooLarge { class });
		}
		let used = self.remaining(rate, now) + u64::from(amount) * MINUTE_MS;
		let capacity = u64::from(rate.burst) * MINUTE_MS;
		if used > capacity {
			return Err(Refusal::Throttled {
				class,
				retry_ms: (used - capacity).div_ceil(u64::from(rate.per_minute)),
			});
		}
		Ok(())
	}
	pub fn debit(&mut self, rate: Rate, amount: u32, now: u64) {
		self.debt = self.remaining(rate, now) + u64::from(amount) * MINUTE_MS;
		self.at = self.at.max(now);
	}
}
