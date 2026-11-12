//! Advice for the credential that repairs one failed operations import.
use crate::failure::FailureCode;
use alloc::{format, string::String};

/// Explain why one saved operations credential could not be redeemed. The
/// caller classifies the redeem's refusal where it holds the typed binding
/// error, and the capability id selects the exact server token that repairs
/// this intent. Other failures stay verbatim in the runtime issue ledger.
pub fn operations(capability: &str, code: FailureCode) -> Option<String> {
	match code {
		FailureCode::SessionPeerUnverified => Some(
			"That address names the directory by a key its listener does not prove, so this browser cannot trust the answer. Use a door that proves the key: noise-relay, noise-tcp, or iroh."
				.into(),
		),
		FailureCode::SessionCapabilityGone => {
			let token = crate::server::operations::boot_capability(capability)?.token;
			Some(format!(
				"The directory does not recognize that swiss number. Use the value it currently prints as {token}."
			))
		}
		_ => None,
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn operations_failures_name_the_exact_replacement_credential() {
		assert_eq!(
			operations("listeners", FailureCode::SessionCapabilityGone).as_deref(),
			Some(
				"The directory does not recognize that swiss number. Use the value it currently prints as ROOMS-ADMIN-LISTENERS."
			)
		);
		assert!(
			operations("listeners", FailureCode::SessionPeerUnverified)
				.is_some_and(|advice| advice.contains("does not prove") && advice.contains("noise-relay"))
		);
		assert_eq!(operations("listeners", FailureCode::SessionUnreachable), None);
		assert_eq!(operations("unknown", FailureCode::SessionCapabilityGone), None);
	}
}
