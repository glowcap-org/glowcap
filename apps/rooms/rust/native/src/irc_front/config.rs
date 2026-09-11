use glowcap::Locator;
use std::{collections::BTreeMap, net::IpAddr, path::PathBuf};
pub const HELP: &str = "rooms-irc-front [--directory=127.0.0.1:9099] [--bind=127.0.0.1] [--port=6667]\n  --server-name=rooms.local --tls-cert=PATH --tls-key=PATH\n  --dm-transport=noise|tcp|iroh --dm-bind=127.0.0.1 --dm-announce-host=HOST --dm-port=0\n";
pub struct Config {
	pub(super) directory_text: String,
	pub(super) directory: Locator,
	pub(super) bind: String,
	pub(super) port: u16,
	pub(super) server: String,
	pub(super) tls: Option<(PathBuf, PathBuf)>,
	pub(super) dm: DirectListener,
}
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
	pub fn parse(args: impl IntoIterator<Item = String>) -> Result<Option<Self>, String> {
		let mut supplied = BTreeMap::new();
		for arg in args {
			if arg == "--help" {
				return Ok(None);
			}
			let (name, value) = arg
				.strip_prefix("--")
				.and_then(|s| s.split_once('='))
				.ok_or("IRC front options use --name=value")?;
			if !matches!(
				name,
				"directory"
					| "bind" | "port"
					| "server-name" | "tls-cert"
					| "tls-key" | "dm-transport"
					| "dm-bind" | "dm-announce-host"
					| "dm-port"
			) {
				return Err(format!("unknown IRC front option --{name}"));
			}
			if supplied.insert(name.to_owned(), value.to_owned()).is_some() {
				return Err(format!("IRC front option appears twice: --{name}"));
			}
		}
		let value = |key, fallback: &str| supplied.get(key).cloned().unwrap_or_else(|| fallback.into());
		let directory_text = value("directory", "127.0.0.1:9099");
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
		let dm = match value("dm-transport", "noise").as_str() {
			"iroh" => {
				if ["dm-bind", "dm-announce-host", "dm-port"]
					.iter()
					.any(|k| supplied.contains_key(*k))
				{
					return Err("--dm-bind, --dm-announce-host and --dm-port do not apply to iroh".into());
				}
				DirectListener::Iroh
			}
			transport @ ("noise" | "tcp") => {
				let bind = value("dm-bind", "127.0.0.1");
				let announce = supplied.get("dm-announce-host").cloned();
				if wildcard(&bind) && announce.is_none() {
					return Err("a wildcard direct-message bind requires --dm-announce-host".into());
				}
				if transport == "tcp" && (!loopback(&bind) || announce.as_ref().is_some_and(|h| !loopback(h))) {
					return Err(
						"the cleartext direct-message transport is restricted to loopback; use noise or iroh".into(),
					);
				}
				DirectListener::Tcp {
					noise: transport == "noise",
					bind,
					announce,
					port: decimal_port("dm-port", &value("dm-port", "0"))?,
				}
			}
			_ => return Err("--dm-transport must be noise, tcp or iroh".into()),
		};
		Ok(Some(Self {
			directory_text,
			directory,
			bind,
			port,
			server,
			tls,
			dm,
		}))
	}
}
fn loopback(host: &str) -> bool {
	host.eq_ignore_ascii_case("localhost")
		|| host
			.trim_matches(['[', ']'])
			.parse::<IpAddr>()
			.is_ok_and(|a| a.is_loopback())
}
fn wildcard(host: &str) -> bool {
	host.trim_matches(['[', ']'])
		.parse::<IpAddr>()
		.is_ok_and(|a| a.is_unspecified())
}
fn decimal_port(name: &str, text: &str) -> Result<u16, String> {
	text.parse()
		.ok()
		.filter(|_| !text.is_empty() && text.bytes().all(|b| b.is_ascii_digit()))
		.ok_or_else(|| format!("--{name} must be a decimal port from 0 through 65535"))
}

#[cfg(test)]
mod tests {
	use super::*;
	fn parse(args: &[&str]) -> Result<Option<Config>, String> {
		Config::parse(args.iter().map(|s| (*s).into()))
	}
	#[test]
	fn front_cli_preserves_endpoint_choices_and_rejects_ambiguous_exposure() {
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
}
