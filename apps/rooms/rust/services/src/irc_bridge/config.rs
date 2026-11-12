use crate::irc::Endpoint;
use rooms_application::server::irc::{
	registration::{SaslPlain, validate_nick, validate_sasl_plain},
	room::Room,
};
use rooms_platform::serving::Transport;
use std::collections::BTreeMap;

pub const HELP: &str = "rooms-irc-bridge --irc-realname='bridge bot; admin: reachable IRC nick'\n  [--network=libera] [--channel=#ocapn] [--irc-host=irc.libera.chat]\n  --irc-port=6697 --irc-nick=glowcap-rooms --tls=true|false\n  --mode=read-only|two-way --sasl-account=ACCOUNT\n  [--transport=<name>] and that transport's listener options\nTwo-way mode requires TLS and GLOWCAP_ROOMS_IRC_SASL_PASSWORD.\nThe Rooms listener is iroh unless --transport or GLOWCAP_ROOMS_IRC_BRIDGE_TRANSPORT\nnames another.\n";

pub struct Config {
	pub(super) network: String,
	pub(super) channel: String,
	pub(super) nick: String,
	pub(super) realname: String,
	pub(super) endpoint: Endpoint,
	pub(super) tls: bool,
	pub(super) sasl: Option<SaslPlain>,
	pub(super) transport: Transport,
}
impl Config {
	/// The options that describe the IRC side. The Rooms listener takes the
	/// transport's own.
	const IRC: &'static [&'static str] = &[
		"network",
		"channel",
		"irc-host",
		"irc-port",
		"irc-nick",
		"irc-realname",
		"mode",
		"sasl-account",
		"tls",
	];
	/// Every option `parse` reads.
	pub fn options() -> impl Iterator<Item = &'static str> {
		Self::IRC.iter().chain(Transport::OPTIONS).copied()
	}
	/// The environment variable that stands in for an absent listener option.
	pub fn variable(key: &str) -> String {
		format!("GLOWCAP_ROOMS_IRC_BRIDGE_{}", key.replace('-', "_").to_uppercase())
	}
	/// `None` means help was asked for. The IRC side is named by arguments
	/// alone, and the SASL password by the environment alone.
	pub fn parse(
		args: impl IntoIterator<Item = String>,
		env: impl Fn(&str) -> Option<String>,
	) -> Result<Option<Self>, String> {
		let mut supplied = BTreeMap::new();
		for arg in args {
			if arg == "--help" {
				return Ok(None);
			}
			let (name, value) = arg
				.strip_prefix("--")
				.and_then(|a| a.split_once('='))
				.ok_or("IRC bridge options use --name=value")?;
			if !Self::options().any(|option| option == name) {
				// Unknown values may be attempted credentials; never repeat them.
				return Err(format!("unknown IRC bridge option --{name}"));
			}
			if supplied.insert(name.to_owned(), value.to_owned()).is_some() {
				return Err(format!("IRC bridge option appears twice: --{name}"));
			}
		}
		let value = |key, fallback: &str| supplied.get(key).cloned().unwrap_or_else(|| fallback.into());
		let network = value("network", "libera");
		let channel = value("channel", "#ocapn");
		let nick = value("irc-nick", "glowcap-rooms");
		validate_nick(&nick)?;
		let realname = supplied
			.get("irc-realname")
			.map(|value| value.trim().to_owned())
			.filter(|value| !value.is_empty())
			.ok_or("IRC bridge requires --irc-realname='bot name; admin: reachable Libera nick'")?;
		rooms_application::server::irc::registration::validate_realname(&realname)?;
		Room::<u64, ()>::new(&network, &channel, &nick, "validation", &network)?;
		let tls = match value("tls", "true").as_str() {
			"true" => true,
			"false" => false,
			_ => return Err("--tls must be true or false".into()),
		};
		let sasl = match value("mode", "read-only").as_str() {
			"two-way" => {
				if !tls {
					return Err("two-way IRC requires TLS so SASL PLAIN credentials are not exposed".into());
				}
				let credentials = SaslPlain {
					account: supplied
						.get("sasl-account")
						.ok_or("two-way IRC requires --sasl-account=ACCOUNT")?
						.clone(),
					password: env("GLOWCAP_ROOMS_IRC_SASL_PASSWORD")
						.ok_or("two-way IRC requires GLOWCAP_ROOMS_IRC_SASL_PASSWORD")?,
				};
				validate_sasl_plain(&credentials)?;
				Some(credentials)
			}
			"read-only" if supplied.contains_key("sasl-account") => {
				return Err("--sasl-account requires --mode=two-way".into());
			}
			"read-only" => None,
			_ => return Err("--mode must be read-only or two-way".into()),
		};
		let port = decimal_port(&value("irc-port", "6697"))?;
		let endpoint = Endpoint::new(&value("irc-host", "irc.libera.chat"), port, tls)?;
		let transport = Transport::parse(|key| supplied.get(key).cloned(), &env, Self::variable, "IRC bridge")?;
		Ok(Some(Self {
			network,
			channel,
			nick,
			realname,
			endpoint,
			tls,
			sasl,
			transport,
		}))
	}
}
fn decimal_port(value: &str) -> Result<u16, String> {
	rooms_application::host::port(value)
		.filter(|port| *port != 0)
		.ok_or_else(|| "--irc-port requires a decimal port from 1 through 65535".into())
}

#[cfg(test)]
mod tests {
	use super::*;
	fn parse(args: &[&str], password: Option<&str>) -> Result<Option<Config>, String> {
		let mut complete = vec!["--irc-realname=bridge bot; admin: alice"];
		complete.extend_from_slice(args);
		Config::parse(complete.into_iter().map(str::to_owned), |key| {
			password
				.filter(|_| key == "GLOWCAP_ROOMS_IRC_SASL_PASSWORD")
				.map(str::to_owned)
		})
	}
	#[test]
	fn read_only_defaults_require_a_public_identity_and_never_read_secrets() {
		assert!(Config::parse([], |_| panic!("missing identity read credentials")).is_err());
		let config = Config::parse(["--irc-realname=bridge bot; admin: alice".to_owned()], |key| {
			assert_ne!(
				key, "GLOWCAP_ROOMS_IRC_SASL_PASSWORD",
				"read-only startup read credentials"
			);
			None
		})
		.unwrap()
		.unwrap();
		assert!(config.tls);
		assert_eq!(config.network, "libera");
		assert_eq!(config.channel, "#ocapn");
		assert_eq!(config.realname, "bridge bot; admin: alice");
		assert!(config.sasl.is_none());
	}
	/// A room is readable by everyone who can read its listener, so the
	/// bridge listens sealed until its operator names a cleartext transport.
	#[test]
	fn the_rooms_listener_is_sealed_unless_the_operator_names_another() {
		use rooms_application::server::operations::listeners::{self, Transport as Profile};
		use rooms_platform::serving::TcpProfile;
		let sealed = parse(&[], None).unwrap().unwrap();
		assert_eq!(sealed.transport.profile(), Profile::Iroh);
		let named = parse(&["--transport=tcp", "--port=7000"], None).unwrap().unwrap();
		assert!(matches!(
			named.transport,
			Transport::Tcp {
				profile: TcpProfile::Plain,
				port: 7000,
				announce: None,
				..
			}
		));
		let listener = |args: &[&str]| {
			let mut complete = vec!["--irc-realname=bridge bot; admin: alice"];
			complete.extend_from_slice(args);
			Config::parse(complete.into_iter().map(str::to_owned), |key| {
				(key == "GLOWCAP_ROOMS_IRC_BRIDGE_TRANSPORT").then(|| "noise-tcp".to_owned())
			})
			.unwrap()
			.unwrap()
			.transport
			.profile()
		};
		assert_eq!(listener(&[]), Profile::NoiseTcp);
		assert_eq!(listener(&["--transport=iroh"]), Profile::Iroh);
		assert_eq!(
			parse(&["--transport=tcp", "--bind=0.0.0.0"], None).err().unwrap(),
			"IRC bridge wildcard bind needs --announce-host=<dialable-host>"
		);
		assert_eq!(
			parse(&["--bind=127.0.0.1", "--port=7000"], None).err().unwrap(),
			"IRC bridge --bind does not apply to the iroh transport"
		);
		assert_eq!(
			parse(&["--transport=quic"], None).err().unwrap(),
			format!(
				"IRC bridge transport must be one of {}",
				listeners::TRANSPORTS.map(Profile::name).join(", ")
			)
		);
	}
	#[test]
	fn two_way_credentials_require_tls_and_never_accept_an_argv_password() {
		let args = [
			"--mode=two-way",
			"--sasl-account=bridge-account",
			"--irc-nick=bridgebot",
		];
		let config = parse(&args, Some("bridge-password")).unwrap().unwrap();
		let sasl = config.sasl.unwrap();
		assert_eq!(sasl.account, "bridge-account");
		assert_eq!(sasl.password, "bridge-password");
		assert!(
			parse(&args, None)
				.err()
				.unwrap()
				.contains("GLOWCAP_ROOMS_IRC_SASL_PASSWORD")
		);
		let mut insecure = args.to_vec();
		insecure.push("--tls=false");
		assert!(
			parse(&insecure, Some("bridge-password"))
				.err()
				.unwrap()
				.contains("requires TLS")
		);
		let mut argv = args.to_vec();
		argv.push("--sasl-password=argv-secret");
		let error = parse(&argv, Some("ignored")).err().unwrap();
		assert!(error.contains("unknown IRC bridge option"));
		assert!(!error.contains("argv-secret"));
	}
	#[test]
	fn ambiguous_and_lossy_options_are_refused() {
		for args in [
			vec!["--transport=tcp", "--port=-1"],
			vec!["--transport=tcp", "--port=+1"],
			vec!["--port=7000"],
			vec!["--irc-port=0"],
			vec!["--irc-port=+6697"],
			vec!["--tls=yes"],
			vec!["--mode=read-only", "--sasl-account=unused"],
			vec!["--network=one", "--network=two"],
			vec!["--irc-nick=9invalid"],
		] {
			assert!(parse(&args, None).is_err(), "accepted {args:?}");
		}
	}
}
