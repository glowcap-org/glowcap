//! Registering a listener at a WebSocket relay, for the boot listener and a
//! runtime seat alike. The host provider keeps registration retries in the
//! background, so a completed listen is not the evidence the relay exists:
//! one register socket opened and closed first is, and the registration
//! itself answers within one deadline or the listener refuses.
use glowcap::{Host, ListenerIdentity, relay};
use rooms_application::server::operations::listeners::{Refusal, register_url};
use std::time::Duration;

/// How long the relay has to answer a register socket, and then the
/// registration, before the listener refuses instead of standing behind
/// a row nothing answers.
pub const REGISTER_DEADLINE: Duration = Duration::from_secs(5);

/// Which relay profile a relay listener speaks.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Profile {
	/// Cleartext through the relay, dialed by key designator.
	Keyed,
	/// Noise_XK sealed end to end; the relay forwards only ciphertext.
	Noise,
}

/// One relay under the two addresses a listener needs: how this server
/// reaches it, and how peers dial it, which the door advertises. Behind a
/// port forward or a proxy the two differ.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Address {
	pub reach: String,
	pub dial: String,
}

impl Address {
	/// The server's relay: reached at `reach` (`--relay`), dialed by peers at
	/// `public` (`--relay-public`) when one is named. `None` when no relay
	/// is configured.
	pub fn configured(reach: Option<String>, public: Option<String>) -> Result<Option<Self>, Refusal> {
		let Some(reach) = reach else {
			return match public {
				Some(_) => Err(Refusal::unsupported(
					"--relay-public names a relay as peers dial it, so --relay or GLOWCAP_ROOMS_RELAY_URL must name how this server reaches it.",
				)),
				None => Ok(None),
			};
		};
		register_url(&reach)?;
		let dial = match public {
			Some(public) => {
				register_url(&public)?;
				public
			}
			None => reach.clone(),
		};
		Ok(Some(Self { reach, dial }))
	}
	/// A relay an ask names by URL. The server's own relay named by its
	/// public address is reached the way the server reaches it; any other
	/// relay is reached as named.
	pub fn named(url: String, configured: Option<&Self>) -> Result<Self, Refusal> {
		if let Some(configured) = configured
			&& configured.dial == url
		{
			return Ok(configured.clone());
		}
		register_url(&url)?;
		Ok(Self {
			reach: url.clone(),
			dial: url,
		})
	}
}

/// Register the Host at `address`. An unsupported refusal names the relay
/// that did not answer; a plain one is the provider's own failure.
pub async fn listen(profile: Profile, address: &Address, host: &Host) -> Result<relay::Server, Refusal> {
	let Address { reach, dial } = address;
	let register = register_url(reach)?;
	let designator = host.designator().map_err(|e| Refusal::plain(e.to_string()))?;
	probe(&register, &designator).await?;
	let options = relay::ListenOptions {
		identity: ListenerIdentity::Host(host.clone()),
		trust: Default::default(),
		relay_alias_url: (dial != reach).then_some(dial.as_str()),
	};
	let registering = async {
		match profile {
			Profile::Keyed => relay::keyed::listen(reach, &register, options).await,
			Profile::Noise => relay::noise::listen(reach, &register, options).await,
		}
	};
	tokio::time::timeout(REGISTER_DEADLINE, registering)
		.await
		.map_err(|_| Refusal::unsupported("The relay did not answer a register socket in time."))?
		.map_err(|error| Refusal::plain(error.to_string()))
}

/// Open one register socket to prove the relay answers, then close it.
async fn probe(register: &str, designator: &str) -> Result<(), Refusal> {
	let url = format!("{register}?id={designator}");
	let connect = tokio_tungstenite::connect_async(&url);
	match tokio::time::timeout(REGISTER_DEADLINE, connect).await {
		Ok(Ok((mut socket, _))) => {
			// The probe registered nothing to keep: a close frame ends it, and
			// the relay drops the registration with it. A relay that is gone
			// before the frame lands has still answered the probe.
			drop(socket.close(None).await); // tolerant: the probe's answer is the open, not the close
			Ok(())
		}
		Ok(Err(_)) => Err(Refusal::unsupported(format!(
			"No relay answered a register socket at {register}."
		))),
		Err(_) => Err(Refusal::unsupported(
			"The relay did not answer a register socket in time.",
		)),
	}
}

#[cfg(test)]
mod tests {
	use super::Address;

	#[test]
	fn a_relay_named_by_its_public_address_is_reached_the_way_the_server_reaches_it() {
		let own = Address::configured(
			Some("ws://127.0.0.1:8080/relay".into()),
			Some("wss://rooms.example/relay".into()),
		)
		.unwrap()
		.unwrap();
		assert_eq!(own.reach, "ws://127.0.0.1:8080/relay");
		assert_eq!(
			Address::named("wss://rooms.example/relay".into(), Some(&own)).unwrap(),
			own
		);
		let other = Address::named("wss://relay.example/relay".into(), Some(&own)).unwrap();
		assert_eq!(other.dial, "wss://relay.example/relay");
		assert_eq!(other.reach, "wss://relay.example/relay");
		assert_eq!(Address::configured(None, None).unwrap(), None);
		assert!(Address::configured(None, Some("wss://rooms.example/relay".into())).is_err());
	}
}
