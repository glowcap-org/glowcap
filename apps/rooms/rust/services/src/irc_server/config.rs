use crate::session::Dial;
use glowcap::Locator;
use rooms_application::host::{loopback, wildcard};
use std::{collections::BTreeMap, path::PathBuf};
pub const HELP: &str = "rooms-irc-server --directory=<the address rooms-server printed> [--bind=127.0.0.1] [--port=6667]\n  --server-name=rooms.local --tls-cert=PATH --tls-key=PATH\n  --dm-transport=noise-tcp|iroh|tcp --dm-bind=127.0.0.1 --dm-announce-host=HOST --dm-port=0  (tcp is cleartext and binds loopback only)\n  --dial-transports=<name>[,<name>...]  also dial members on noise-tcp, iroh, keyed-tcp, tcp (tcp and keyed-tcp are cleartext)\n";
pub struct Config {
	pub(super) directory_text: String,
	pub(super) directory: Locator,
	pub(super) bind: String,
	pub(super) port: u16,
	pub(super) server: String,
	pub(super) tls: Option<(PathBuf, PathBuf)>,
	pub(super) dm: DirectListener,
	/// The transports the operator let this server dial beside the
	/// directory's and the direct-message listener's.
	pub(super) dial: Vec<Dial>,
}
/// What `--dial-transports` offers here. An IRC client is no browser, and
/// this server runs no onion proxy.
const DIALS: [Dial; 4] = [Dial::NoiseTcp, Dial::Iroh, Dial::KeyedTcp, Dial::Tcp];
pub(super) enum DirectListener {
	Iroh,
	Tcp {
		noise: bool,
		bind: String,
		announce: Option<String>,
		port: u16,
	},
}
impl Config {
	/// The TCP profiles this server and each of its clients register. The
	/// operator names a cleartext one through the directory's transport, the
	/// direct-message listener's, or `--dial-transports`.
	pub(super) fn tcp(&self) -> glowcap::tcp::Config {
		let listening = match &self.dm {
			DirectListener::Tcp { noise: false, .. } => Some(glowcap::TRANSPORT_TCP),
			DirectListener::Tcp { noise: true, .. } | DirectListener::Iroh => None,
		};
		rooms_platform::serving::tcp_config(
			std::iter::once(self.directory.transport.as_str())
				.chain(listening)
				.chain(self.dial.iter().map(|dial| dial.name())),
		)
	}
	/// The iroh posture this server and each of its clients dial with, when
	/// the directory, the direct-message listener, or `--dial-transports`
	/// names iroh. Beside a TCP directory it dials through discovery, the only
	/// way to find a member from its node id.
	pub(super) fn iroh(&self) -> Option<glowcap::iroh::Reachability> {
		(self.directory.transport == glowcap::TRANSPORT_IROH
			|| matches!(self.dm, DirectListener::Iroh)
			|| self.dial.contains(&Dial::Iroh))
		.then(|| self.directory_reachability())
	}
	/// How the server's iroh endpoint reaches the directory. A locator that
	/// carries direct addresses is dialed as it says, with no relay and no
	/// lookup. A bare node id, the form a discovery-published server prints,
	/// can only be resolved through discovery, so that posture follows the
	/// locator rather than being a second flag the operator has to know.
	pub(super) fn directory_reachability(&self) -> glowcap::iroh::Reachability {
		if self.directory.hints.contains_key(glowcap::HINT_DIRECT_ADDRESSES) {
			glowcap::iroh::Reachability::Direct
		} else {
			glowcap::iroh::Reachability::Discovery
		}
	}
	/// Every option `parse` reads.
	pub const OPTIONS: &'static [&'static str] = &[
		"directory",
		"bind",
		"port",
		"server-name",
		"tls-cert",
		"tls-key",
		"dm-transport",
		"dm-bind",
		"dm-announce-host",
		"dm-port",
		"dial-transports",
	];
	pub fn parse(args: impl IntoIterator<Item = String>) -> Result<Option<Self>, String> {
		let mut supplied = BTreeMap::new();
		for arg in args {
			if arg == "--help" {
				return Ok(None);
			}
			let (name, value) = arg
				.strip_prefix("--")
				.and_then(|s| s.split_once('='))
				.ok_or("IRC server options use --name=value")?;
			if !Self::OPTIONS.contains(&name) {
				return Err(format!("unknown IRC server option --{name}"));
			}
			if supplied.insert(name.to_owned(), value.to_owned()).is_some() {
				return Err(format!("IRC server option appears twice: --{name}"));
			}
		}
		let value = |key, fallback: &str| supplied.get(key).cloned().unwrap_or_else(|| fallback.into());
		let directory_text = supplied
			.get("directory")
			.cloned()
			.ok_or("--directory must name the Rooms server to serve")?;
		let directory =
			rooms_glowcap::routes::locator(&directory_text).ok_or("--directory must name a Rooms locator")?;
		let bind = value("bind", "127.0.0.1");
		let port = decimal_port("port", &value("port", "6667"))?;
		let server = value("server-name", "rooms.local");
		if server.is_empty()
			|| server.len() > 63
			|| !server.as_bytes()[0].is_ascii_alphanumeric()
			|| !server
				.bytes()
				.all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-')
		{
			return Err("--server-name must be a 1..63 character IRC server name".into());
		}
		let tls = match (supplied.get("tls-cert"), supplied.get("tls-key")) {
			(None, None) => None,
			(Some(cert), Some(key)) if !cert.is_empty() && !key.is_empty() => Some((cert.into(), key.into())),
			_ => return Err("--tls-cert and --tls-key must be supplied together with nonempty paths".into()),
		};
		if !loopback(&bind) && tls.is_none() {
			return Err("a non-loopback IRC bind requires --tls-cert and --tls-key".into());
		}
		let dm = match value("dm-transport", glowcap::TRANSPORT_NOISE_TCP).as_str() {
			glowcap::TRANSPORT_IROH => {
				if ["dm-bind", "dm-announce-host", "dm-port"]
					.iter()
					.any(|k| supplied.contains_key(*k))
				{
					return Err("--dm-bind, --dm-announce-host and --dm-port do not apply to iroh".into());
				}
				DirectListener::Iroh
			}
			transport @ (glowcap::TRANSPORT_NOISE_TCP | glowcap::TRANSPORT_TCP) => {
				let bind = value("dm-bind", "127.0.0.1");
				let announce = supplied.get("dm-announce-host").cloned();
				if wildcard(&bind) && announce.is_none() {
					return Err("a wildcard direct-message bind requires --dm-announce-host".into());
				}
				let noise = transport == glowcap::TRANSPORT_NOISE_TCP;
				if !noise && (!loopback(&bind) || announce.as_ref().is_some_and(|h| !loopback(h))) {
					return Err(
						"the cleartext direct-message transport is restricted to loopback, so use noise-tcp or iroh"
							.into(),
					);
				}
				DirectListener::Tcp {
					noise,
					bind,
					announce,
					port: decimal_port("dm-port", &value("dm-port", "0"))?,
				}
			}
			_ => return Err("--dm-transport must be noise-tcp, iroh or tcp".into()),
		};
		let dial = match supplied.get("dial-transports") {
			Some(names) => Dial::parse_list(names, &DIALS)?,
			None => Vec::new(),
		};
		Ok(Some(Self {
			directory_text,
			directory,
			bind,
			port,
			server,
			tls,
			dm,
			dial,
		}))
	}
}
fn decimal_port(name: &str, text: &str) -> Result<u16, String> {
	rooms_application::host::port(text).ok_or_else(|| format!("--{name} must be a decimal port from 0 through 65535"))
}

#[cfg(test)]
mod tests {
	use super::*;
	const LOCAL: &str = "--directory=127.0.0.1:9099";
	/// Parse with a loopback directory unless the arguments name one.
	fn parse(args: &[&str]) -> Result<Option<Config>, String> {
		let named = args.iter().any(|arg| arg.starts_with("--directory="));
		let directory = (!named).then_some(LOCAL);
		Config::parse(directory.iter().chain(args).map(|s| (*s).into()))
	}
	#[test]
	fn iroh_reachability_follows_the_directory_locator() {
		let node = "b".repeat(64);
		let bare = parse(&[&format!("--directory=ocapn://{node}.iroh")]).unwrap().unwrap();
		assert_eq!(bare.directory_reachability(), glowcap::iroh::Reachability::Discovery);
		let hinted = parse(&[&format!(
			"--directory=ocapn://{node}.iroh?direct-addresses=127.0.0.1%3A4433"
		)])
		.unwrap()
		.unwrap();
		assert_eq!(hinted.directory_reachability(), glowcap::iroh::Reachability::Direct);
	}
	#[test]
	fn server_cli_preserves_endpoint_choices_and_rejects_ambiguous_exposure() {
		let config = parse(&[]).unwrap().unwrap();
		assert_eq!(
			(
				config.directory_text.as_str(),
				config.bind.as_str(),
				config.port,
				config.server.as_str()
			),
			("127.0.0.1:9099", "127.0.0.1", 6667, "rooms.local")
		);
		assert!(matches!(
			config.dm,
			DirectListener::Tcp {
				noise: true,
				port: 0,
				..
			}
		));
		assert!(config.tls.is_none());
		assert!(matches!(
			parse(&["--dm-transport=tcp"]).unwrap().unwrap().dm,
			DirectListener::Tcp { noise: false, .. }
		));
		assert!(matches!(
			parse(&["--dm-transport=iroh"]).unwrap().unwrap().dm,
			DirectListener::Iroh
		));
		// A cleartext profile is registered only where the operator named it.
		use glowcap::tcp::Profiles;
		let profiles = |args: &[&str]| parse(args).unwrap().unwrap().tcp().profiles;
		let iroh = format!("--directory=ocapn://{}.iroh", "b".repeat(64));
		let iroh = iroh.as_str();
		assert!(
			Config::parse([]).is_err(),
			"a server with no directory named one for itself"
		);
		assert_eq!(profiles(&[]), Profiles::NOISE_TCP.with(Profiles::TCP));
		assert_eq!(profiles(&[iroh]), Profiles::NOISE_TCP);
		assert_eq!(profiles(&[iroh, "--dm-transport=iroh"]), Profiles::NOISE_TCP);
		assert_eq!(
			profiles(&[iroh, "--dm-transport=tcp"]),
			Profiles::NOISE_TCP.with(Profiles::TCP)
		);
		let named = format!("--dial-transports={}", glowcap::TRANSPORT_KEYED_TCP);
		assert_eq!(profiles(&[iroh, &named]), Profiles::NOISE_TCP.with(Profiles::KEYED_TCP));
		assert_eq!(
			parse(&[iroh, "--dial-transports=iroh,onion"]).err().as_deref(),
			Some("--dial-transports takes noise-tcp, iroh, keyed-tcp, tcp, not \"onion\"")
		);
		// The sealed listener has one name, the one a locator carries.
		assert_eq!(
			parse(&["--dm-transport=noise"]).err().as_deref(),
			Some("--dm-transport must be noise-tcp, iroh or tcp")
		);
		// iroh is dialed when the directory, the listener, or the flag names it.
		let dials_iroh = |args: &[&str]| parse(args).unwrap().unwrap().iroh().is_some();
		let flag = format!("--dial-transports={}", glowcap::TRANSPORT_IROH);
		assert!(!dials_iroh(&[]));
		assert!(dials_iroh(&[iroh]) && dials_iroh(&["--dm-transport=iroh"]) && dials_iroh(&[&flag]));
		let public = parse(&[
			"--bind=0.0.0.0",
			"--tls-cert=cert.pem",
			"--tls-key=key.pem",
			"--dm-bind=0.0.0.0",
			"--dm-announce-host=rooms.example",
		])
		.unwrap()
		.unwrap();
		assert!(public.tls.is_some());
		for args in [
			vec!["--bind=0.0.0.0"],
			vec!["--port=-1"],
			vec!["--server-name=bad server"],
			vec!["--tls-cert=cert.pem"],
			vec!["--tls-cert=", "--tls-key="],
			vec!["--dm-bind=::"],
			vec!["--port=1", "--port=2"],
			vec!["--unknown=yes"],
			vec!["--dm-transport=iroh", "--dm-port=1"],
			vec![
				"--dm-transport=tcp",
				"--dm-bind=0.0.0.0",
				"--dm-announce-host=rooms.example",
			],
		] {
			assert!(parse(&args).is_err(), "accepted {args:?}");
		}
	}
	#[test]
	fn the_help_names_every_dial_transport() {
		let offered = format!("also dial members on {} (", DIALS.map(Dial::name).join(", "));
		assert!(HELP.contains(&offered), "{offered}");
	}
}
