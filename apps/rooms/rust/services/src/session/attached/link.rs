//! Reaching the capability a link names. A use link and a management link are
//! both sturdyrefs at one session, and both are dialed the same way.
use super::Error;
use glowcap::{CaptpVersion, ConnectOptions, Locator, Ref, Runtime};
use rooms_application::room::authority::REQUEST_TIMEOUT_MS;
use rooms_glowcap::client::{Client, Deadline, Error as ClientError};

/// What a call says when the session did not answer within its deadline.
pub(super) const NO_ANSWER: &str = "the session did not answer";

/// A dialed session, the capability the link names, and where the link
/// leads, which links to other capabilities of the same session reuse.
pub(super) struct Reached<D> {
	pub client: Client<D>,
	pub reference: Ref,
	pub locator: Locator,
}

/// A failed fetch of the capability a link names. The answer that the session
/// holds no such publication, which `is_publication_not_found` names, is
/// refused: the link is unknown or retired, and never recovers. Any other
/// failure is no verdict on the link. A lost connection is unreachable, and a
/// lookup that failed or was limited is the peer's own answer with the cause
/// it carries, so a caller that retries a peer's answer retries it.
pub(super) fn refused_or_failed(error: ClientError) -> Error {
	match &error {
		ClientError::Binding(binding) if binding.is_publication_not_found() => Error::Refused,
		_ => failure(error),
	}
}

/// A failed call that asked about an access that was reached. A broken
/// connection is unreachable, and any other answer is the peer's own, with
/// the advice it carries. Neither says the access is refused.
pub(super) fn failure(error: ClientError) -> Error {
	if error.connection_failed() {
		Error::Unreachable(error)
	} else {
		Error::Peer(error)
	}
}

pub(super) async fn reach<D: Deadline + Clone>(
	runtime: &Runtime,
	platform: D,
	link: &str,
) -> Result<Reached<D>, Error> {
	let parsed = glowcap::parse_sturdyref(link.trim(), CaptpVersion::V1_0)
		.map_err(|_| Error::Input("not a session link".into()))?;
	let swiss = std::str::from_utf8(&parsed.swissnum).map_err(|_| Error::Input("not a session link".into()))?;
	let reach = async {
		let connection = runtime
			.connect(&parsed.locator, ConnectOptions::default())
			.await
			.map_err(|error| Error::Unreachable(error.into()))?;
		let reference = connection.fetch(swiss).await.map_err(ClientError::from);
		Ok::<_, Error>((connection, reference))
	};
	let (connection, reference) = platform
		.within(REQUEST_TIMEOUT_MS, reach)
		.await
		.ok_or(Error::Unreachable(ClientError::Timeout(NO_ANSWER)))??;
	let reference = reference.map_err(refused_or_failed)?;
	Ok(Reached {
		client: Client::new(connection, platform),
		reference,
		locator: parsed.locator,
	})
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn a_failed_describe_is_the_peers_answer_and_never_a_refused_access() {
		let peer = failure(ClientError::RefusedObservation("rate-limited: wait".into()));
		assert!(matches!(peer, Error::Peer(_)), "{peer:?}");
		let lost = failure(ClientError::Timeout(NO_ANSWER));
		assert!(matches!(lost, Error::Unreachable(_)), "{lost:?}");
		// A fetch that failed or was limited is no verdict on the link: only the
		// peer's typed "publication gone" answer is `Refused`. That answer is
		// proved against a live session in `session_process`.
		assert!(matches!(
			refused_or_failed(ClientError::RefusedObservation("unknown".into())),
			Error::Peer(_)
		));
		assert!(matches!(
			refused_or_failed(ClientError::Timeout(NO_ANSWER)),
			Error::Unreachable(_)
		));
	}
}
