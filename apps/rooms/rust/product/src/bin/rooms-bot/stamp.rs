//! The time a log line carries: UTC, RFC 3339, whole seconds. No Rooms crate
//! formats a date, and the log is the only place the bot needs one, so this
//! is the whole conversion.
use std::time::{SystemTime, UNIX_EPOCH};

/// The date and time of `seconds` after the Unix epoch, such as
/// `2026-11-21T09:30:05Z`.
pub fn rfc3339(seconds: u64) -> String {
	let days = i64::try_from(seconds / 86_400).unwrap_or(i64::MAX / 2);
	let rest = seconds % 86_400;
	// The civil-from-days conversion of Howard Hinnant's date algorithms.
	let shifted = days + 719_468;
	let era = shifted.div_euclid(146_097);
	let day_of_era = shifted.rem_euclid(146_097);
	let year_of_era = (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
	let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
	let month_index = (5 * day_of_year + 2) / 153;
	let day = day_of_year - (153 * month_index + 2) / 5 + 1;
	let month = if month_index < 10 {
		month_index + 3
	} else {
		month_index - 9
	};
	let year = year_of_era + era * 400 + i64::from(month <= 2);
	let (hour, minute, second) = (rest / 3_600, rest % 3_600 / 60, rest % 60);
	format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}Z")
}

/// The time now. A clock before the epoch reads as the epoch, since a log
/// line is worth writing at any time.
pub fn now() -> String {
	let seconds = SystemTime::now()
		.duration_since(UNIX_EPOCH)
		.map_or(0, |since| since.as_secs());
	rfc3339(seconds)
}

#[cfg(test)]
mod tests {
	use super::rfc3339;

	#[test]
	fn seconds_become_utc_dates() {
		assert_eq!(rfc3339(0), "1970-01-01T00:00:00Z");
		assert_eq!(rfc3339(951_782_400), "2000-02-29T00:00:00Z");
		assert_eq!(rfc3339(1_709_210_096), "2024-02-29T12:34:56Z");
		assert_eq!(rfc3339(1_795_253_405), "2026-11-21T09:30:05Z");
		assert_eq!(rfc3339(4_102_444_799), "2099-12-31T23:59:59Z");
	}
}
