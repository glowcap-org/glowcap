use super::{Error, HORIZON, stamp};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum When {
	After(u64),
	At(u64),
}

impl When {
	pub fn parse(relative: Option<&str>, absolute: Option<&str>) -> Result<Self, Error> {
		if let (Some(value), None) = (relative, absolute) {
			let parts = value.as_bytes().split_last().and_then(|(unit, n)| {
				let scale = match unit {
					b's' => 1,
					b'm' => 60,
					b'h' => 3600,
					b'd' => 86_400,
					_ => return None,
				};
				if !n.iter().all(u8::is_ascii_digit) {
					return None;
				}
				std::str::from_utf8(n).ok()?.parse::<u64>().ok()?.checked_mul(scale)
			});
			if let Some(seconds @ 1..=HORIZON) = parts {
				return Ok(Self::After(seconds));
			}
		}
		if let (None, Some(value)) = (relative, absolute)
			&& value.len() == 20
			&& value.is_ascii()
		{
			// Compare fixed-width UTC timestamps using the same calendar used
			// for output. Exact equality rejects invalid dates and leap seconds.
			let (mut low, mut high) = (0, 253_402_300_799u64);
			while low < high {
				let mid = low + (high - low) / 2;
				if stamp::rfc3339(mid).as_str() < value {
					low = mid + 1;
				} else {
					high = mid;
				}
			}
			if stamp::rfc3339(low) == value {
				return Ok(Self::At(low));
			}
		}
		Err(Error::Usage(
			"give exactly one of --in (e.g. 20m, units s/m/h/d) or --at YYYY-MM-DDTHH:MM:SSZ".into(),
		))
	}

	pub(super) fn due(self, now: u64) -> Result<u64, Error> {
		let due = match self {
			Self::After(seconds) => now.saturating_add(seconds),
			Self::At(at) => at,
		};
		if (1..=HORIZON).contains(&due.saturating_sub(now)) {
			Ok(due)
		} else {
			Err(Error::Usage(
				"the reminder must be in the future and within 30 days".into(),
			))
		}
	}
}

/// A bounded number of slots at a fixed cadence, including the first slot.
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Repeat {
	pub every_seconds: u64,
	pub count: u32,
}

impl Repeat {
	pub fn parse(every: Option<&str>, count: Option<&str>) -> Result<Option<Self>, Error> {
		match (every, count) {
			(None, None) => Ok(None),
			(Some(every), Some(count)) => {
				if let When::After(every_seconds @ 60..) = When::parse(Some(every), None)?
					&& count.bytes().all(|b| b.is_ascii_digit())
					&& let Ok(count @ 2..=32) = count.parse::<u32>()
				{
					return Ok(Some(Self { every_seconds, count }));
				}
				Err(Error::Usage(
					"repeat every minute or longer, with --count 2 through 32".into(),
				))
			}
			_ => Err(Error::Usage("repeating reminders take both --every and --count".into())),
		}
	}
	pub(super) fn span(self) -> u64 {
		self.every_seconds * u64::from(self.count - 1)
	}
}
