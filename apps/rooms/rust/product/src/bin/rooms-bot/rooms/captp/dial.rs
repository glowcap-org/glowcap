//! Reaching a session over CapTP: a Host, a Runtime with the transport the
//! link names, and an attached view. `serve` dials with a Host built from its
//! stored identity so its peers see one bot. An action verb dials with a fresh
//! Host and leaves nothing behind.
use crate::bot::{error::Error, link::Link};
use glowcap::{Host, PendingWork, Runtime, RuntimeConfig, iroh};
use rooms_platform::HostPlatform;
use rooms_services::session::attached::{self, View};
use std::fmt;

/// The transports a session link can name that this bot dials.
#[derive(Clone, Copy)]
enum Family {
	Tcp(&'static str),
	Iroh,
}

/// Where a bot dials and as whom.
pub struct Dial {
	link: Link,
	family: Family,
	seed: Option<[u8; 32]>,
}

/// Why a dial did not produce a view.
#[derive(Debug)]
pub enum Failure {
	/// The Host or its Runtime could not be opened.
	Platform(glowcap::Error),
	/// The session refused or did not answer the attach.
	Attach(attached::Error),
}

impl fmt::Display for Failure {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::Platform(error) => write!(f, "the bot's CapTP host could not start: {error}"),
			Self::Attach(error) => error.fmt(f),
		}
	}
}

/// A dialed session. Closing it releases the Host and every connection.
pub struct Live {
	runtime: Runtime,
	pub view: View<HostPlatform>,
	pub grant: String,
}

impl Live {
	/// Close the Host. A failure here has no caller who can act on it, so it
	/// is reported to the caller to note and the Host is gone either way.
	pub async fn close(&self) -> Result<(), glowcap::Error> {
		self.runtime.close(PendingWork::Cancel).await
	}
}

/// Refuse a cleartext `tcp` link that leaves this machine. Plain `tcp`
/// carries the bot's traffic unencrypted and unauthenticated, so it is for a
/// session on the same machine. `designator` is the link's `host:port`.
fn cleartext_reach(designator: &str) -> Result<(), Error> {
	let host = designator.rsplit_once(':').map_or(designator, |(host, _)| host);
	if rooms_application::host::loopback(host) {
		return Ok(());
	}
	Err(Error::Config(
		"this session link uses plain tcp to another machine, which nobody could trust. Issue the access from a session that serves keyed-tcp or noise-tcp, or reach the session on this machine"
			.into(),
	))
}

impl Dial {
	/// Dial `link`. With a `seed` the Host keeps that identity across dials.
	/// A link on a transport this bot does not dial is a configuration error.
	pub fn new(link: Link, seed: Option<[u8; 32]>) -> Result<Self, Error> {
		let parsed = glowcap::parse_sturdyref(link.as_str(), glowcap::CaptpVersion::V1_0)
			.map_err(|_| Error::Config("the session link cannot be read".into()))?;
		let family = match parsed.locator.transport.as_str() {
			glowcap::TRANSPORT_TCP => {
				cleartext_reach(&parsed.locator.designator)?;
				Family::Tcp(glowcap::TRANSPORT_TCP)
			}
			glowcap::TRANSPORT_KEYED_TCP => Family::Tcp(glowcap::TRANSPORT_KEYED_TCP),
			glowcap::TRANSPORT_NOISE_TCP => Family::Tcp(glowcap::TRANSPORT_NOISE_TCP),
			glowcap::TRANSPORT_IROH => Family::Iroh,
			other => {
				return Err(Error::Config(format!(
					"the bot attaches over tcp, keyed-tcp, noise-tcp, or iroh, and this link names {other}"
				)));
			}
		};
		Ok(Self { link, family, seed })
	}

	/// Open a Host and Runtime and attach a view. A failed attach closes what
	/// it opened.
	pub async fn attach(&self) -> Result<Live, Failure> {
		let options = rooms_glowcap::host_options();
		let host = match self.seed {
			Some(seed) => Host::from_seed_with_options(seed, options),
			None => Host::with_options(options),
		}
		.map_err(Failure::Platform)?;
		let provider = match self.family {
			Family::Tcp(transport) => glowcap::tcp::provider(rooms_platform::serving::tcp_config([transport])),
			Family::Iroh => iroh::provider(rooms_platform::serving::iroh_config(iroh::Reachability::Discovery)),
		};
		let runtime = match Runtime::open(RuntimeConfig::providers([provider]).adopt_host(&host)).await {
			Ok(runtime) => runtime,
			Err(error) => {
				// best-effort: the failure to open is the report, and an unopened
				// Host holds nothing a later dial would miss.
				let _ = host.close(PendingWork::Cancel).await;
				return Err(Failure::Platform(error));
			}
		};
		match View::attach(&runtime, HostPlatform, self.link.as_str()).await {
			Ok(view) => Ok(Live {
				runtime,
				view,
				grant: self.link.fingerprint(),
			}),
			Err(error) => {
				// best-effort: the attach error is the report, and the Host is
				// discarded whether or not it closes cleanly.
				let _ = runtime.close(PendingWork::Cancel).await;
				Err(Failure::Attach(error))
			}
		}
	}
}

#[cfg(test)]
mod tests {
	use super::{Dial, cleartext_reach};
	use crate::bot::link::Link;

	/// The designator a link names, read the way `Dial::new` reads it.
	fn designator(link: &str) -> String {
		glowcap::parse_sturdyref(link, glowcap::CaptpVersion::V1_0)
			.unwrap()
			.locator
			.designator
	}

	#[test]
	fn plain_tcp_reaches_only_this_machine() {
		for link in [
			"ocapn://127.0.0.1%3A9201.tcp/s/Ym9hcmQ",
			"ocapn://127.0.0.2%3A9201.tcp/s/Ym9hcmQ",
			"ocapn://localhost%3A9201.tcp/s/Ym9hcmQ",
			"ocapn://%5B%3A%3A1%5D%3A9201.tcp/s/Ym9hcmQ",
		] {
			assert!(cleartext_reach(&designator(link)).is_ok(), "{link}");
		}
		for link in [
			"ocapn://192.168.1.4%3A9201.tcp/s/Ym9hcmQ",
			"ocapn://rooms.example%3A9201.tcp/s/Ym9hcmQ",
			"ocapn://%5B2001%3Adb8%3A%3A1%5D%3A9201.tcp/s/Ym9hcmQ",
		] {
			assert!(cleartext_reach(&designator(link)).is_err(), "{link}");
		}
	}

	#[test]
	fn a_dial_refuses_plain_tcp_to_another_machine_before_it_connects() {
		let dial = |link: &str| Dial::new(Link::parse(link).unwrap(), None);
		assert!(dial("ocapn://127.0.0.1%3A9201.tcp/s/Ym9hcmQ").is_ok());
		let Err(refused) = dial("ocapn://192.168.1.4%3A9201.tcp/s/Ym9hcmQ") else {
			panic!("a plain tcp link to another machine was dialed");
		};
		assert!(refused.to_string().contains("plain tcp"), "{refused}");
		assert!(dial("ocapn://192.168.1.4%3A9201.noise-tcp/s/Ym9hcmQ").is_ok());
	}
}
