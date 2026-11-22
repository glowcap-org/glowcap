//! Reaching the capability a link names. A use link and a management link are
//! both sturdyrefs at one session, and both are dialed the same way.
use super::Error;
use glowcap::{CaptpVersion, ConnectOptions, Locator, Ref, Runtime};
use rooms_application::room::authority::REQUEST_TIMEOUT_MS;
use rooms_glowcap::client::{Client, Deadline, Error as ClientError};

/// A dialed session, the capability the link names, and where the link
/// leads, which links to other capabilities of the same session reuse.
pub(super) struct Reached<D> {
	pub client: Client<D>,
	pub reference: Ref,
	pub locator: Locator,
}

/// A failed call is unreachable when the connection broke and refused when the
/// peer answered without admitting the request.
pub(super) fn refusal(error: ClientError) -> Error {
	if error.connection_failed() {
		Error::Unreachable(error)
	} else {
		Error::Refused
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
		.ok_or(Error::Unreachable(ClientError::Timeout("the session did not answer")))??;
	let reference = reference.map_err(refusal)?;
	Ok(Reached {
		client: Client::new(connection, platform),
		reference,
		locator: parsed.locator,
	})
}
