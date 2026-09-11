//! Product advice for opening an existing shared session. Unknown diagnostics
//! retain their original meaning; these recognizers grant no retry authority.
use alloc::{format, string::String};

enum ConnectionFailure {
	Unreachable,
	Handshake,
}

fn connection_failure(reason: &str) -> Option<ConnectionFailure> {
	if reason.contains("NetworkUnreachable") || reason.contains("Connection refused") {
		return Some(ConnectionFailure::Unreachable);
	}
	if reason.contains("did not finish the OCapN handshake")
		|| reason.contains("connection closed during the OCapN handshake")
	{
		return Some(ConnectionFailure::Handshake);
	}
	None
}

/// Explain a directory connection failure at the owner that also knows it will
/// retry. Unknown peer and transport diagnostics remain intact for operators.
pub fn directory(reason: &str) -> Option<&'static str> {
	match connection_failure(reason)? {
		ConnectionFailure::Unreachable => Some(
			"The room directory could not be reached. This session will keep retrying; check that the directory is running and reachable.",
		),
		ConnectionFailure::Handshake => Some(
			"The room directory was reached, but it did not finish the OCapN handshake. This session will keep retrying; check that the directory is running compatible code.",
		),
	}
}

pub fn attachment(reason: &str) -> Option<&'static str> {
	match connection_failure(reason) {
		Some(ConnectionFailure::Unreachable) => return Some("The shared session peer could not be reached. Make sure it is running and retry the capability it currently announces. An iroh session needs either a reachable advertised address or working iroh discovery and relay access."),
		Some(ConnectionFailure::Handshake) => return Some("The session peer was reached, but it did not finish the OCapN handshake. Check that the Rooms session peer is running compatible code, then retry."),
		None => {}
	}
	if reason.contains("unknown swissnum") {
		return Some("The session peer does not know this capability. It was probably revoked, or belongs to a session that no longer exists. Use one the session shows now.");
	}
	if reason.contains("no signaling inbox for that designator") {
		return Some("The hosting tab is not answering WebRTC on the directory this capability names. On that tab, Share the session and leave it open. Reloading it ends sharing.");
	}
	if reason.contains("signalOffer needs a registered name") {
		return Some("This browser could not signal through the directory the capability names. Retry after that directory is reachable from here.");
	}
	if reason.contains("PeerIdentityUnverified") {
		return Some("The session peer answered, but this browser could not authenticate that it is the peer the capability names. Retry with a capability the session shows now.");
	}
	None
}

/// Explain why one saved operations credential could not be redeemed. The
/// capability id selects the exact server token that repairs this intent;
/// unknown failures stay verbatim in the runtime issue ledger.
pub fn operations(capability: &str, reason: &str) -> Option<String> {
	if !reason.contains("unknown swissnum") {
		return None;
	}
	let token = crate::server::operations::boot_capability(capability)?.token;
	Some(format!(
		"The directory does not recognize that swiss number. Use the value it currently prints as {token}."
	))
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn signaling_and_identity_refusals_preserve_the_actual_failure_subject() {
		for (reason, subject) in [
			(
				"glowcap error -12: peer-offline: no signaling inbox for that designator",
				"hosting tab",
			),
			(
				"glowcap error -12: not-registered: signalOffer needs a registered name",
				"could not signal through the directory",
			),
			(
				"glowcap error -3: host: PeerIdentityUnverified",
				"could not authenticate",
			),
			("host: NetworkUnreachable", "could not be reached"),
			("broken promise: unknown swissnum", "does not know this capability"),
			("peer did not finish the OCapN handshake", "compatible code"),
		] {
			let advice = attachment(reason).unwrap();
			assert!(advice.contains(subject), "{advice}");
			// The presentation's locator refusal reader must not reinterpret these
			// peer facts as a damaged paste of a capability.
			assert!(!advice.starts_with("glowcap error"));
			assert!(!advice.contains("Check that you pasted"));
		}
		assert_eq!(attachment("unexpected observer failure"), None);
	}

	#[test]
	fn directory_connection_failures_name_recovery_without_hiding_unknown_diagnostics() {
		for reason in [
			"host: NetworkUnreachable",
			"Connection refused (os error 111)",
			"glowcap error -7: connection closed during the OCapN handshake",
			"peer did not finish the OCapN handshake",
		] {
			let advice = directory(reason).unwrap();
			assert!(advice.contains("retrying"), "{advice}");
			assert!(advice.contains("reach"), "{advice}");
			assert!(!advice.starts_with("glowcap error"), "{advice}");
		}
		assert_eq!(directory("unexpected observer failure"), None);
	}

	#[test]
	fn operations_failures_name_the_exact_replacement_credential() {
		assert_eq!(
			operations("listeners", "glowcap error -12: unknown swissnum").as_deref(),
			Some(
				"The directory does not recognize that swiss number. Use the value it currently prints as ROOMS-ADMIN-LISTENERS."
			)
		);
		assert_eq!(operations("listeners", "connection closed"), None);
		assert_eq!(operations("unknown", "unknown swissnum"), None);
	}
}
