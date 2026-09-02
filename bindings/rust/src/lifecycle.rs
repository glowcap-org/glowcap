use std::time::Duration;

use crate::sys;
use crate::sys::host::GlowcapCloseOptions;
use crate::{Error, Result};

/// Whether a final native release crossed its ownership boundary. Host and
/// driver release share one pre-commit refusal: INVALID_ARGUMENT. Every other
/// status is a teardown outcome and names an already-consumed handle.
pub(crate) fn release_consumed(code: i32) -> bool {
	code != sys::ERR_INVALID_ARGUMENT
}

/// What explicit close does with operations admitted before its barrier.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PendingWork {
	/// Interrupt admitted work and wait for physical cancellation to complete.
	Cancel,
	/// Let admitted work settle before closing. `None` is an explicitly
	/// unbounded finish; implicit resource cleanup always uses [`Cancel`](Self::Cancel).
	Finish { grace: Option<Duration> },
}

impl PendingWork {
	pub(crate) fn to_ffi(self) -> Result<GlowcapCloseOptions> {
		let (pending, grace_mode, grace_ms) = match self {
			Self::Cancel => (sys::PENDING_CANCEL, sys::CLOSE_GRACE_UNSPECIFIED, 0),
			Self::Finish { grace: None } => (sys::PENDING_FINISH, sys::CLOSE_GRACE_UNBOUNDED, 0),
			Self::Finish { grace: Some(grace) } => {
				let nanos = grace.as_nanos();
				let millis = nanos.saturating_add(999_999) / 1_000_000;
				if millis > u128::from(sys::CLOSE_MAX_GRACE_MS) {
					return Err(Error::with_detail(
						sys::ERR_INVALID_ARGUMENT,
						format!("finish grace must not exceed {} milliseconds", sys::CLOSE_MAX_GRACE_MS),
					));
				}
				let grace_ms = u32::try_from(millis).map_err(|_| {
					Error::with_detail(sys::ERR_INVALID_ARGUMENT, "finish grace cannot be represented".into())
				})?;
				(sys::PENDING_FINISH, sys::CLOSE_GRACE_FINITE, grace_ms)
			}
		};
		Ok(GlowcapCloseOptions {
			abi_version: sys::CLOSE_OPTIONS_ABI_VERSION,
			struct_size: std::mem::size_of::<GlowcapCloseOptions>(),
			pending,
			grace_mode,
			grace_ms,
		})
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn final_release_status_names_the_ownership_boundary() {
		assert!(!release_consumed(sys::ERR_INVALID_ARGUMENT));
		assert!(release_consumed(sys::OK));
		assert!(release_consumed(sys::ERR_IO));
		assert!(release_consumed(sys::ERR_INTERNAL));
	}

	#[test]
	fn finite_grace_preserves_the_c_field_representation() {
		let maximum = PendingWork::Finish {
			grace: Some(Duration::from_millis(u64::from(sys::CLOSE_MAX_GRACE_MS))),
		}
		.to_ffi()
		.expect("the native maximum is representable");
		assert_eq!(maximum.grace_ms, sys::CLOSE_MAX_GRACE_MS);

		let above = PendingWork::Finish {
			grace: Some(Duration::from_millis(u64::from(sys::CLOSE_MAX_GRACE_MS) + 1)),
		}
		.to_ffi();
		assert!(above.is_err());
	}
}
