//! Rooms server options. Everything is parsed before durable custody is
//! acquired, so a refused option never leaves a lock or a half-written
//! document behind. Every option may come from the environment as
//! `GLOWCAP_ROOMS_<NAME>`, and an argument wins.
use super::{error::Error, operations::Asked};
use rooms_application::server::operations::listeners::{self, Ask};
pub use rooms_platform::serving::Transport;
use std::{collections::BTreeMap, path::PathBuf};

pub struct Config {
	pub admission: rooms_application::admission::Settings,
	/// Where the server document, its history, and its lock live. Without
	/// one the server is process-local: a fresh identity each start, and
	/// nothing kept past it.
	pub state: Option<PathBuf>,
	/// The announced listener, the one every printed locator names.
	pub transport: Transport,
	/// The listeners declared beside it, up before the server is ready and
	/// held only for this run. One declaration per transport, none for the
	/// announced one.
	pub listen: Vec<(listeners::Transport, Ask)>,
	/// Whether rooms keep their last lines. They persist under the
	/// state directory, or stay in memory when there is none.
	pub history: bool,
	/// The boot capabilities to mint and publish.
	pub asked: Asked,
	/// The loopback port the live timeline endpoint binds while `trace` is
	/// asked. Zero takes an ephemeral one.
	pub trace_port: u16,
	pub trace_publish: Option<String>,
	pub trace_connect: Option<String>,
}

/// The timeline endpoint's port when nothing overrides it.
pub const TRACE_PORT: u16 = 9300;

pub const HELP: &str = "rooms-server [--state=<directory>] [--transport=<transport>] [--listen=<transport>[,<name>=<value>...]]... [--history]
  --state=<directory>  keep the server document, history, and operator choices here across restarts
  --transport=<transport>  the announced listener: tcp, keyed-tcp, noise-tcp, iroh (default), keyed-relay, noise-relay, or onion
  --listen=<transport>[,<name>=<value>...]  also listen over tcp, keyed-tcp, noise-tcp, iroh, keyed-relay, noise-relay, or onion; repeatable, one per transport
      tcp, keyed-tcp, noise-tcp take bind, port, advertise; keyed-relay, noise-relay take relay (or GLOWCAP_ROOMS_RELAY_URL)
  --history  keep the last lines of each room
  --admission-scale=<1..100>  scale default work allowances (default: 1)
  --admission-rates=<class=burst/per-minute,...>  absolute per-class overrides
  --admission-rows=<1..65536>  retained subject row cap (default: 8192)
  --admission-aggregate-scale=<1..100>  deployment pool multiplier (default: 1)
  --reachability=discovery|direct  iroh reachability (default: discovery)
  --bind=<host> --port=<port> --announce-host=<host>  tcp, keyed-tcp, noise-tcp listener options
  --relay=<ws-url>  the relay a keyed-relay or noise-relay listener registers at and peers dial (or GLOWCAP_ROOMS_RELAY_URL)
  --relay-public=<ws-url>  the same relay as peers dial it, when a port forward or proxy gives it another address (or GLOWCAP_ROOMS_RELAY_PUBLIC_URL; default --relay)
  --onion-socks=<endpoint> --onion-control=<endpoint>  running Tor endpoints (or GLOWCAP_ONION_SOCKS/CONTROL)
  --port=<port>  onion local forward port; 0 chooses an ephemeral loopback port
  --onion-forward=<absolute-path>  bind a Unix forwarding socket instead (requires --port=0)
  --admin-listeners --diagnostics --operator --peering --irc --trace  mint an operator capability and print its swiss
  --trace-port=<port>  the loopback port the live timeline endpoint binds (default: 9300; 0 takes any)
  --trace-connect=<ws-url>  advertise the CapTP byte-channel endpoint through a deployment proxy
  --trace-publish=<ws-url>  advertise the producer endpoint through a deployment proxy
Options override GLOWCAP_ROOMS_* environment variables. TCP defaults to 127.0.0.1:0.
rooms-server --capabilities[=<state-directory>]  print kept operator capabilities without starting a server
The directory defaults to GLOWCAP_ROOMS_STATE. Kept capabilities may be disabled in the current server.
Set GLOWCAP_ROOMS_LOCATOR to the server's advertised locator to print complete recipes.
For a minted timeline, also set GLOWCAP_ROOMS_TRACE_LOCATOR to its advertised locator.
";

/// The options beyond the transport's own that take a value.
const KEYS: &[&str] = &["state", "trace-port", "trace-publish", "trace-connect"];
/// The one option that repeats, read in the listener seats' own grammar.
pub const LISTEN: &str = "listen";
/// The options that are flags: present, or `1`/`true`/`yes` in the environment.
const FLAGS: &[&str] = &[
	"history",
	"admin-listeners",
	"diagnostics",
	"operator",
	"peering",
	"irc",
	"trace",
];

impl Config {
	/// The environment variable that stands in for an absent `--<key>`.
	pub fn variable(key: &str) -> String {
		format!("GLOWCAP_ROOMS_{}", key.replace('-', "_").to_uppercase())
	}
	/// `None` means help was asked for. An argument wins over the environment.
	pub fn parse(
		args: impl IntoIterator<Item = String>,
		env: impl Fn(&str) -> Option<String>,
	) -> Result<Option<Self>, Error> {
		let mut named = BTreeMap::new();
		let mut declared = Vec::new();
		for arg in args {
			if arg == "--help" || arg == "-h" {
				return Ok(None);
			}
			let Some(option) = arg.strip_prefix("--") else {
				return Err(Error::refused("options use --name=value"));
			};
			let (key, value) = option.split_once('=').unwrap_or((option, "1"));
			if key == LISTEN {
				if !option.contains('=') {
					return Err(Error::refused(format!("--{key} takes a value")));
				}
				declared.push(value.to_owned());
				continue;
			}
			if !KEYS.contains(&key)
				&& !FLAGS.contains(&key)
				&& !Transport::OPTIONS.contains(&key)
				&& !rooms_application::admission::Settings::OPTIONS.contains(&key)
			{
				return Err(Error::refused(format!("unknown option: --{key}")));
			}
			if !FLAGS.contains(&key) && !option.contains('=') {
				return Err(Error::refused(format!("--{key} takes a value")));
			}
			if named.insert(key.to_owned(), value.to_owned()).is_some() {
				return Err(Error::refused(format!("repeated option: --{key}")));
			}
		}
		let value = |key: &str| {
			named.get(key).cloned().or_else(|| {
				env(&Self::variable(key))
					.map(|s| s.trim().to_owned())
					.filter(|s| !s.is_empty())
			})
		};
		let flag = |key: &str| -> Result<Option<bool>, Error> {
			match value(key).as_deref() {
				None => Ok(None),
				Some("1" | "true" | "yes") => Ok(Some(true)),
				Some("0" | "false" | "no") => Ok(Some(false)),
				Some(other) => Err(Error::refused(format!("--{key} takes no value, not {other:?}"))),
			}
		};
		let transport =
			Transport::parse(|key| named.get(key).cloned(), &env, Self::variable, "server").map_err(Error::refused)?;
		// The environment stands in only when no argument declared one, the
		// way every other option's argument wins over its variable.
		if declared.is_empty()
			&& let Some(listed) = env("GLOWCAP_ROOMS_LISTEN")
		{
			declared.extend(listed.split_whitespace().map(str::to_owned));
		}
		let listen = Self::listeners(&transport, &declared)?;
		let history = flag("history")?.unwrap_or(false);
		let asked = Asked {
			admin_listeners: flag("admin-listeners")?.unwrap_or(false),
			diagnostics: flag("diagnostics")?.unwrap_or(false),
			operator: flag("operator")?.unwrap_or(false),
			peering: flag("peering")?.unwrap_or(false),
			irc: flag("irc")?.unwrap_or(false),
			trace: flag("trace")?.unwrap_or(false),
		};
		let trace_port = match value("trace-port") {
			None => TRACE_PORT,
			Some(port) => port
				.parse::<u16>()
				.map_err(|_| Error::refused("--trace-port must be an integer from 0 through 65535"))?,
		};
		Ok(Some(Self {
			admission: rooms_application::admission::Settings::parse_from(
				|key| {
					value(key).map(|v| {
						(
							v,
							if named.contains_key(key) {
								rooms_application::admission::Source::Argument
							} else {
								rooms_application::admission::Source::Environment
							},
						)
					})
				},
				rooms_application::admission::DIRECTORY_ROWS,
				1,
			)
			.map_err(String::from)
			.map_err(Error::refused)?,
			state: value("state").map(PathBuf::from),
			transport,
			listen,
			history,
			asked,
			trace_port,
			trace_connect: value("trace-connect")
				.map(|endpoint| {
					rooms_application::web_channel::endpoint(&endpoint).map_err(Error::refused)?;
					Ok::<_, Error>(endpoint)
				})
				.transpose()?,
			trace_publish: value("trace-publish")
				.map(|endpoint| {
					rooms_application::server::trace::producer_endpoint(&endpoint).map_err(Error::refused)?;
					Ok::<_, Error>(endpoint)
				})
				.transpose()?,
		}))
	}
	/// The declared listeners, each read the way `up` reads it, refused
	/// whole when one repeats a transport or names the announced one.
	fn listeners(announced: &Transport, declared: &[String]) -> Result<Vec<(listeners::Transport, Ask)>, Error> {
		let boot = announced.profile();
		let mut listen: Vec<(listeners::Transport, Ask)> = Vec::with_capacity(declared.len());
		for text in declared {
			let (transport, ask) = Ask::parse(text)
				.map_err(|refusal| Error::refused(format!("--{LISTEN}={text}: {}", refusal.detail())))?;
			if transport == boot {
				return Err(Error::refused(format!(
					"--{LISTEN}={text} names the announced transport; --transport already listens over {}",
					transport.name()
				)));
			}
			if listen.iter().any(|(held, _)| *held == transport) {
				return Err(Error::refused(format!(
					"--{LISTEN}={text} repeats a transport; a server holds one {} listener",
					transport.name()
				)));
			}
			listen.push((transport, ask));
		}
		Ok(listen)
	}
	/// The history directory under the state directory. With history on and
	/// no state directory, lines live in memory.
	pub fn history_directory(&self) -> Option<PathBuf> {
		if !self.history {
			return None;
		}
		self.state.as_ref().map(|root| root.join("history"))
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	fn parse(args: &[&str], env: impl Fn(&str) -> Option<String>) -> Result<Config, String> {
		match Config::parse(args.iter().map(|arg| (*arg).to_owned()), env) {
			Ok(config) => Ok(config.expect("a launch")),
			Err(error) => Err(error.to_string()),
		}
	}

	#[test]
	fn declared_listeners_repeat_once_per_transport_beside_the_announced_one() {
		let config = parse(
			&[
				"--transport=tcp",
				"--listen=noise-relay",
				"--listen=noise-tcp,port=7,bind=::1",
			],
			|_| None,
		)
		.unwrap();
		let declared: Vec<_> = config.listen.iter().map(|(transport, _)| transport.name()).collect();
		assert_eq!(declared, ["noise-relay", "noise-tcp"]);
		assert_eq!(config.listen[1].1.port, Some(7));
		let refused = |args: &[&str]| parse(args, |_| None).err().expect("a refusal");
		assert!(refused(&["--listen"]).contains("--listen takes a value"));
		assert!(refused(&["--listen=iroh"]).contains("names the announced transport"));
		assert!(refused(&["--listen=noise-tcp", "--listen=noise-tcp,port=1"]).contains("repeats a transport"));
		assert!(refused(&["--listen=tcp,port=x"]).contains("--listen=tcp,port=x: port is an integer"));
		// The environment stands in only when no argument declared one.
		let env = |key: &str| (key == "GLOWCAP_ROOMS_LISTEN").then(|| "noise-relay noise-tcp,port=0".to_owned());
		let config = parse(&[], env).unwrap();
		assert_eq!(config.listen.len(), 2);
		let config = parse(&["--listen=keyed-tcp"], env).unwrap();
		assert_eq!(config.listen.len(), 1);
		assert_eq!(config.listen[0].0, listeners::Transport::KeyedTcp);
	}

	#[test]
	fn every_listener_profile_is_an_announced_transport() {
		let relay = |key: &str| (key == "GLOWCAP_ROOMS_RELAY_URL").then(|| "ws://127.0.0.1:8080/relay".to_owned());
		for name in listeners::TRANSPORTS.map(listeners::Transport::name) {
			let env = |key: &str| match key {
				"GLOWCAP_ONION_SOCKS" | "GLOWCAP_ONION_CONTROL" => Some("127.0.0.1:1".to_owned()),
				_ => relay(key),
			};
			let config = parse(&[&format!("--transport={name}")], env).unwrap();
			assert_eq!(config.transport.profile().name(), name);
			let listen = format!("--listen={name}");
			let refused = parse(&[&format!("--transport={name}"), &listen], env)
				.err()
				.expect("a refusal");
			assert!(refused.contains("names the announced transport"), "{refused}");
		}
		let config = parse(
			&[
				"--transport=noise-relay",
				"--relay=wss://relay.example/relay",
				"--listen=keyed-relay",
			],
			|_| None,
		)
		.unwrap();
		let Transport::Relay { address, .. } = &config.transport else {
			panic!("a relay transport");
		};
		assert_eq!(address.dial, "wss://relay.example/relay");
		assert_eq!(address.reach, "wss://relay.example/relay");
		// A declared relay listener reads its relay from its own option or
		// the environment, as a declared tcp listener reads its bind.
		assert_eq!(config.listen[0].1.relay, None);
		// Behind a port forward the server reaches its relay at one address
		// and the door advertises another.
		let config = parse(
			&[
				"--transport=noise-relay",
				"--relay=ws://127.0.0.1:8080/relay",
				"--relay-public=wss://rooms.example/relay",
			],
			|_| None,
		)
		.unwrap();
		let Transport::Relay { address, .. } = &config.transport else {
			panic!("a relay transport");
		};
		assert_eq!(address.dial, "wss://rooms.example/relay");
		assert_eq!(address.reach, "ws://127.0.0.1:8080/relay");
		let refused = |args: &[&str]| parse(args, |_| None).err().expect("a refusal");
		let refusal = refused(&["--transport=noise-relay"]);
		assert!(
			refusal.contains("--relay=<ws-url> or GLOWCAP_ROOMS_RELAY_URL"),
			"{refusal}"
		);
		let refusal = refused(&["--transport=noise-relay", "--relay-public=wss://rooms.example/relay"]);
		assert!(
			refusal.contains("--relay or GLOWCAP_ROOMS_RELAY_URL must name"),
			"{refusal}"
		);
		let refusal = refused(&["--transport=noise-relay", "--relay=http://x/"]);
		assert!(refusal.contains("uses ws or wss"), "{refusal}");
		let refusal = refused(&["--transport=quic"]);
		assert!(
			refusal.contains("tcp, keyed-tcp, noise-tcp, iroh, keyed-relay, noise-relay, onion"),
			"{refusal}"
		);
	}
}
