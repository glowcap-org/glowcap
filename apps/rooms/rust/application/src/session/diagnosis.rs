//! Product advice for opening an existing shared session. Unknown diagnostics
//! retain their original meaning. These recognizers grant no retry authority.
use crate::failure::{Failure, FailureCode};
use alloc::{format, string::String};

#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Advice {
	pub code: &'static str,
	pub subject: &'static str,
	pub retry: &'static str,
	pub summary: &'static str,
	pub action: &'static str,
}

fn advice(code: FailureCode) -> Advice {
	let definition = code.definition();
	#[expect(
		clippy::expect_used,
		reason = "every definition `advice` is asked for carries a repair action; `FailureCode::definition` is the table"
	)]
	Advice {
		code: definition.code.wire(),
		subject: definition.subject,
		retry: definition.retry.wire(),
		summary: definition.summary,
		action: definition.action.expect("session failure advice has a repair action"),
	}
}

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

pub fn attachment(reason: &str) -> Option<Advice> {
	// The browser's own restoration timeouts carry this code in their line;
	// the binding's `RestorationFailed` kind arrives as its rendered name.
	if Failure::parse(reason).is_some_and(|failure| failure.code == FailureCode::SessionRestorationFailed)
		|| reason == "glowcap error -12: RestorationFailed"
	{
		return Some(advice(FailureCode::SessionRestorationFailed));
	}
	match connection_failure(reason) {
		Some(ConnectionFailure::Unreachable) => {
			return Some(advice(FailureCode::SessionUnreachable));
		}
		Some(ConnectionFailure::Handshake) => {
			return Some(advice(FailureCode::SessionHandshakeIncomplete));
		}
		None => {}
	}
	if reason.contains("unknown swissnum") {
		return Some(advice(FailureCode::SessionCapabilityGone));
	}
	if reason.contains("no signaling inbox for that designator") {
		return Some(advice(FailureCode::SessionSignalingHostOffline));
	}
	if reason.contains("signalOffer needs a registered name") {
		return Some(advice(FailureCode::SessionSignalingUnavailable));
	}
	if reason.contains("WebRTC could not establish or retain a route")
		|| reason.contains("peers found no route to each other")
	{
		return Some(advice(FailureCode::SessionWebrtcNoRoute));
	}
	if reason.contains("PeerIdentityUnverified") {
		return Some(advice(FailureCode::SessionPeerUnverified));
	}
	None
}

/// Explain why one saved operations credential could not be redeemed. The
/// capability id selects the exact server token that repairs this intent.
/// Unknown failures stay verbatim in the runtime issue ledger.
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
				"glowcap error -8: WebRTC could not establish or retain a route; cleanup failed: WebRTC could not establish or retain a route",
				"WebRTC found no route",
			),
			(
				"glowcap error -3: host: PeerIdentityUnverified",
				"could not authenticate",
			),
			("host: NetworkUnreachable", "could not be reached"),
			("broken promise: unknown swissnum", "does not know this capability"),
			("glowcap error -12: RestorationFailed", "could not be restored"),
			(
				"session-restoration-failed: Saved workspace connection timed out",
				"attach its new session link",
			),
			(
				"session-restoration-failed: Saved management connection timed out",
				"could not be restored",
			),
			("peer did not finish the OCapN handshake", "compatible code"),
		] {
			let advice = attachment(reason).unwrap();
			let rendered = format!("{} {}", advice.summary, advice.action);
			assert!(rendered.contains(subject), "{rendered}");
			// The presentation's locator refusal reader must not reinterpret these
			// peer facts as a damaged paste of a capability.
			assert!(!rendered.starts_with("glowcap error"));
			assert!(!rendered.contains("Check that you pasted"));
		}
		assert_eq!(
			attachment("peers found no route to each other").unwrap().code,
			"session-webrtc-no-route"
		);
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
