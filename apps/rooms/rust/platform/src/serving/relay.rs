//! Registering a listener at a WebSocket relay, for the boot listener and a
//! runtime seat alike. The host provider registers in the background and
//! keeps retrying there, so a completed listen is not the evidence the relay
//! exists. One probe is: a register request the relay refuses as a Rooms
//! relay does, which registers nothing and touches no live registration.
use glowcap::{Host, ListenerIdentity, relay};
use rooms_application::server::operations::listeners::{Refusal, register_url};
use std::time::Duration;

/// How long the relay has to answer the probe before the listener refuses
/// instead of standing behind a row nothing answers.
pub const REGISTER_DEADLINE: Duration = Duration::from_secs(5);
/// The identity the probe registers under: not a designator, so a Rooms
/// relay refuses it before any effect, and that refusal is the proof.
const PROBE_IDENTITY: &str = "probe";
/// The line a Rooms relay refuses a non-designator identity with.
const PROBE_REFUSAL: &str = "invalid rendezvous identity";

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
	/// The dial route when it differs from the reach route: the alias a
	/// listener advertises, and what a supervised directory is told.
	pub fn public(&self) -> Option<&str> {
		(self.dial != self.reach).then_some(self.dial.as_str())
	}
}

/// Register the Host at `address`. An unsupported refusal names the relay
/// that did not answer as one; a plain one is the provider's own failure.
/// The open completes once the provider holds the registration to retry,
/// in process, so it waits on no partner.
pub async fn listen(profile: Profile, address: &Address, host: &Host) -> Result<relay::Server, Refusal> {
	let reach = &address.reach;
	let register = register_url(reach)?;
	probe(&register).await?;
	let options = relay::ListenOptions {
		identity: ListenerIdentity::Host(host.clone()),
		trust: Default::default(),
		relay_alias_url: address.public(),
	};
	match profile {
		Profile::Keyed => relay::keyed::listen(reach, &register, options).await,
		Profile::Noise => relay::noise::listen(reach, &register, options).await,
	}
	.map_err(|error| Refusal::plain(error.to_string()))
}

/// Ask `register` to register an identity no relay admits, and read a Rooms
/// relay's refusal of it. Anything else at the address is not one.
async fn probe(register: &str) -> Result<(), Refusal> {
	let url = format!("{register}?id={PROBE_IDENTITY}");
	let connect = tokio_tungstenite::connect_async(&url);
	use tokio_tungstenite::tungstenite::{Error, http::StatusCode};
	match tokio::time::timeout(REGISTER_DEADLINE, connect).await {
		// The status is the answer. The body arrives with the headers or
		// after the handshake stopped reading, so it sharpens the answer
		// only when it came along.
		Ok(Err(Error::Http(response)))
			if response.status() == StatusCode::BAD_REQUEST
				&& response.body().as_deref().is_none_or(|body| {
					body.is_empty() || body.windows(PROBE_REFUSAL.len()).any(|w| w == PROBE_REFUSAL.as_bytes())
				}) =>
		{
			Ok(())
		}
		Ok(Err(Error::Http(response))) => Err(Refusal::unsupported(format!(
			"What answers at {register} is not a Rooms relay: it answered a register request with {}.",
			response.status()
		))),
		Ok(Ok((mut socket, _))) => {
			drop(socket.close(None).await); // tolerant: the socket is refused either way
			Err(Refusal::unsupported(format!(
				"What answers at {register} is not a Rooms relay: it registered an identity no relay admits."
			)))
		}
		Ok(Err(_)) => Err(Refusal::unsupported(format!(
			"No relay answered a register request at {register}."
		))),
		Err(_) => Err(Refusal::unsupported(
			"The relay did not answer a register request in time.",
		)),
	}
}

#[cfg(test)]
mod tests {
	use super::{Address, PROBE_REFUSAL, probe};
	use tokio::io::{AsyncReadExt, AsyncWriteExt};

	/// One HTTP server answering every request with `reply`, at its register
	/// URL, serving until `served` is dropped.
	async fn answering(reply: String, served: &mut tokio::task::JoinSet<()>) -> String {
		let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
		let port = listener.local_addr().unwrap().port();
		served.spawn_local(async move {
			while let Ok((mut socket, _)) = listener.accept().await {
				let mut request = [0u8; 1024];
				let _ = socket.read(&mut request).await;
				let _ = socket.write_all(reply.as_bytes()).await;
			}
		});
		format!("ws://127.0.0.1:{port}/register")
	}

	#[tokio::test]
	async fn the_probe_reads_a_rooms_relays_refusal_and_nothing_else() {
		tokio::task::LocalSet::new()
			.run_until(async {
				let mut served = tokio::task::JoinSet::new();
				let body = format!("rooms: {PROBE_REFUSAL}\n");
				let relay = answering(
					format!(
						"HTTP/1.1 400 Bad Request\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
						body.len()
					),
					&mut served,
				)
				.await;
				assert!(probe(&relay).await.is_ok());
				let other = answering(
					"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".into(),
					&mut served,
				)
				.await;
				let refused = probe(&other).await.unwrap_err();
				assert!(refused.detail().contains("not a Rooms relay"), "{}", refused.detail());
				assert!(refused.detail().contains("404"), "{}", refused.detail());
				let closed = tokio::net::TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
				let nobody = format!("ws://127.0.0.1:{}/register", closed.local_addr().unwrap().port());
				drop(closed);
				let refused = probe(&nobody).await.unwrap_err();
				assert!(refused.detail().contains("No relay answered"), "{}", refused.detail());
				served.shutdown().await;
			})
			.await;
	}

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
