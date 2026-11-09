//! The web command selects HTTP and supervision. Server options retain their
//! existing parser and environment, so both entrypoints validate one contract.
use crate::server;
use rooms_platform::serving::relay;
use std::{collections::BTreeMap, path::PathBuf};

pub struct Config {
	pub(super) admission: super::admission::Config,
	pub bind: String,
	pub port: u16,
	/// The address browsers reach this server at, when it is not the
	/// loopback address of the bound port: what every printed link names.
	pub(super) public: Option<url::Url>,
	pub(super) browser_assets: BrowserAssets,
	pub(super) browser_admission: super::browser_admission::Config,
	pub server: PathBuf,
	pub server_args: Vec<String>,
	pub room: server::Config,
	pub(super) session: Option<Session>,
	pub(super) tor: Option<super::tor::Plan>,
	pub(super) ice: super::ice::Config,
	pub(super) relay: super::relay::Limits,
	/// The relay the peers under this front, the directory and the shared
	/// session, register relay listeners at, when the operator named one.
	/// Otherwise each is handed this server's own relay once the HTTP
	/// address is known.
	pub(super) relay_url: Option<String>,
}
pub(super) enum BrowserAssets {
	Source(PathBuf),
	Prepared(PathBuf),
	Disabled,
}
/// The shared session's options in the session's own grammar. `serve` parses
/// them once the HTTP listener is bound, because a relay door registers at
/// this server's own relay and that address is known then. `Config::parse`
/// validated them against a stand-in for it.
pub(super) struct Session {
	pub args: Vec<String>,
}
pub const HELP: &str = concat!(
	"rooms-web [http-port] [room-port] [options]
  --http-bind=<host> --http-port=<port>  HTTP listener (default: 0.0.0.0:8080)
  --http-public=<url>  the address browsers reach this server at, named by every link it prints (default: http://localhost:<port>/, or GLOWCAP_ROOMS_HTTP_PUBLIC)
  --assets=<directory>  Rooms web source, or an artifact directory with --prepared (default: apps/rooms/web)
  --prepared  serve a prepared bundle without invoking browser build tools
  --no-browser-assets  serve Rooms endpoints without a browser bundle (development tooling)
  --server=<executable>  rooms-server binary (default: beside rooms-web)
  --transport=<transport>  the supervised directory's announced listener: tcp, keyed-tcp, noise-tcp, iroh (default), keyed-relay, noise-relay, or onion
      a relay transport registers at this server's own relay unless GLOWCAP_ROOMS_RELAY_URL or --relay names another, and --relay-public applies only with --relay
      --http-public names this server's own relay as browsers and peers dial it
  --listen=<transport>[,<name>=<value>...]  also listen over another transport, as rooms-server; repeatable
      a relay listener registers at this server's own relay unless GLOWCAP_ROOMS_RELAY_URL or its relay option names another
  --state=<directory>  keep the directory identity and state across restarts
  --session-state=<directory>  also serve a durable shared session and print its use and management links (or GLOWCAP_ROOMS_SESSION_STATE)
  --session-transport=<transport>  the shared session's announced listener: tcp, keyed-tcp, noise-tcp, iroh (default), keyed-relay, noise-relay, or onion
      a relay transport registers at this server's own relay unless GLOWCAP_ROOMS_RELAY_URL or --session-relay names another, and --session-relay-public applies only with --session-relay
  --session-<option>=<value>  any other rooms-session option, such as --session-bind or --session-reachability (or GLOWCAP_ROOMS_SESSION_<OPTION>)
  --history --bind=<host> --announce-host=<host>
  --capabilities=all|<name>[,<name>...]  mint operator capabilities, as rooms-server (or GLOWCAP_ROOMS_CAPABILITIES)
  --http-admission-scale=<1..100> --http-admission-rows=<1..65536>
  --http-admission-rates=<class=burst/per-minute,...> --http-admission-aggregate-scale=<1..100>
  --http-admission-per-address=true|false  charge each source address its own budget (default: false)
  --allow-origin=<origin|page,...>  Rooms pages served elsewhere that may use this server, as origins or page addresses, listed with commas or by repeating the option (default: ", super::relay::site_page!(), ", the page the website publishes, and an empty value allows none). A page address also prints a link that opens it with this server, and with --session-state one that opens it ready to attach (or GLOWCAP_RELAY_ALLOW_ORIGINS)
  --http-trusted-proxies=<address|cidr,...>  proxies whose X-Forwarded-For client address selects the budget (default: none)
  --browser-admission-scale=<1..100> --browser-admission-rows=<1..65536>
  --browser-admission-rates=<class=burst/per-minute,...> --browser-admission-aggregate-scale=<1..100>
Server options and GLOWCAP_ROOMS_* variables have the same meaning as rooms-server.
rooms-web --check-ready[=http://host:port]  check directory and browser assets (5 second deadline)
rooms-web --locator[=http://host:port]  print the running directory locator
rooms-web --ui-version[=http://host:port]  print the running browser revision
rooms-web --page-link[=http://host:port]  print the link that opens the Rooms page with this server, or nothing when no page is allowed
rooms-web --print-capabilities[=<state-directory>] [--url=http://host:port]  print the kept operator capabilities as complete links, with the locators the running front advertises (or GLOWCAP_ROOMS_LOCATOR and GLOWCAP_ROOMS_TRACE_LOCATOR); the directory defaults to GLOWCAP_ROOMS_STATE
Status reads default to http://127.0.0.1:8080, or GLOWCAP_ROOMS_HTTP_PORT.
rooms-web --prepare[=<output-directory>] [--assets=<source-directory>]  build self-contained browser assets
Preparation defaults to zig-out/rooms-web; serve its current directory with --prepared.
rooms-web --export-static=<new-directory> --assets=<prepared-generation> [--base=/<path>/]  write a prepared generation as files for a static host at that base path (default /)
"
);
impl Config {
	pub fn parse(
		args: impl IntoIterator<Item = String>,
		env: impl Fn(&str) -> Option<String>,
	) -> Result<Option<Self>, String> {
		let mut options: BTreeMap<String, String> = BTreeMap::new();
		let mut positional = Vec::new();
		let mut raw_options = BTreeMap::new();
		let mut declared = Vec::new();
		for arg in args {
			if arg == "--help" || arg == "-h" {
				return Ok(None);
			}
			if let Some(option) = arg.strip_prefix("--") {
				let (key, value) = option.split_once('=').unwrap_or((option, "1"));
				// The one repeatable option: every declaration reaches the
				// directory, which reads them in its listeners' own grammar.
				if key == server::LISTEN {
					if !option.contains('=') {
						return Err(needs_value(key));
					}
					declared.push(arg.clone());
					continue;
				}
				let takes_value = matches!(
					key,
					"http-bind" | "http-port" | "http-public" | "assets" | "server" | "allow-origin" | "capabilities"
				) || key.starts_with("http-admission-")
					|| key.starts_with("browser-admission-")
					|| key.starts_with("session-");
				// `--allow-origin=` is a value, the empty list, as its help says.
				let empty_is_value = key == "allow-origin";
				if takes_value && (!option.contains('=') || (value.is_empty() && !empty_is_value)) {
					return Err(needs_value(key));
				}
				// Every option is given once, as every Rooms front reads them: a
				// second value would replace or be dropped without a word, so it
				// is refused. The origin list is the exception, where repeating
				// the option extends the list, the same as one list with commas.
				let value = match options.get(key) {
					Some(prior) if key == "allow-origin" => [prior.as_str(), value]
						.into_iter()
						.filter(|part| !part.is_empty())
						.collect::<Vec<_>>()
						.join(","),
					Some(_) => return Err(format!("repeated option: --{key}")),
					None => value.to_owned(),
				};
				options.insert(key.to_owned(), value);
				raw_options.insert(key.to_owned(), arg.clone());
			} else {
				positional.push(arg);
			}
		}
		if positional.len() > 2 {
			return Err("rooms-web accepts HTTP and room ports as its two positional arguments".into());
		}
		// A port named both ways is one value given twice, like a repeated option.
		if options.contains_key("http-port") && !positional.is_empty() {
			return Err("the HTTP port is given twice, as --http-port and as the first positional argument".into());
		}
		if options.contains_key("port") && positional.len() > 1 {
			return Err("the room port is given twice, as --port and as the second positional argument".into());
		}
		let port = options
			.remove("http-port")
			.or_else(|| positional.first().cloned())
			.or_else(|| env("GLOWCAP_ROOMS_HTTP_PORT"))
			.unwrap_or_else(|| "8080".into())
			.parse::<u16>()
			.map_err(|_| "HTTP port must be an integer from 0 through 65535")?;
		let prepared = match options.remove("prepared").as_deref() {
			None | Some("0" | "false" | "no") => false,
			Some("1" | "true" | "yes") => true,
			Some(_) => return Err("--prepared takes a boolean".into()),
		};
		let no_browser_assets = match options.remove("no-browser-assets").as_deref() {
			None | Some("0" | "false" | "no") => false,
			Some("1" | "true" | "yes") => true,
			Some(_) => return Err("--no-browser-assets takes a boolean".into()),
		};
		let bind = options.remove("http-bind").unwrap_or_else(|| "0.0.0.0".into());
		let public = options
			.remove("http-public")
			.or_else(|| env("GLOWCAP_ROOMS_HTTP_PUBLIC"))
			.filter(|value| !value.is_empty())
			.map(|value| {
				super::relay::exact_address(&value).ok_or_else(|| {
					format!("--http-public (or GLOWCAP_ROOMS_HTTP_PUBLIC) must be an http(s) address ending in /, such as https://rooms.example/, not {value:?}")
				})
			})
			.transpose()?;
		let assets = options.remove("assets").map(PathBuf::from);
		if no_browser_assets && (assets.is_some() || prepared) {
			return Err("--no-browser-assets cannot be combined with --assets or --prepared".into());
		}
		let browser_assets = if no_browser_assets {
			BrowserAssets::Disabled
		} else {
			let root = assets.unwrap_or_else(|| "apps/rooms/web".into());
			if prepared {
				BrowserAssets::Prepared(root)
			} else {
				BrowserAssets::Source(root)
			}
		};
		let server = options
			.remove("server")
			.or_else(|| env("GLOWCAP_ROOMS_SERVER_BIN"))
			.map(PathBuf::from)
			.map(Ok)
			.unwrap_or_else(|| {
				std::env::current_exe()
					.map(|p| p.with_file_name("rooms-server"))
					.map_err(|e| e.to_string())
			})?;
		// The shared session's options, in the session's own grammar: every
		// `--session-<option>` reaches it as `--<option>`, and `--session-state`
		// (or GLOWCAP_ROOMS_SESSION_STATE) turns the session on.
		let mut session = BTreeMap::new();
		let prefixed: Vec<(String, String)> = options
			.keys()
			.filter_map(|key| {
				key.strip_prefix("session-")
					.map(|option| (key.clone(), option.to_owned()))
			})
			.collect();
		for (key, option) in prefixed {
			if !crate::session::Config::accepts(&option) {
				return Err(format!("unknown option: --{key}"));
			}
			if let Some(value) = options.remove(&key) {
				session.insert(option, value);
			}
			raw_options.remove(&key);
		}
		let session_wanted = session.contains_key("state")
			|| env(&crate::session::Config::variable("state")).is_some_and(|state| !state.trim().is_empty());
		if !session_wanted && !session.is_empty() {
			return Err(
				"the shared session's options need --session-state=<directory> or GLOWCAP_ROOMS_SESSION_STATE".into(),
			);
		}
		options
			.entry("port".into())
			.or_insert_with(|| positional.get(1).cloned().unwrap_or_else(|| "9099".into()));
		// A private Tor serves every onion door that names no running Tor:
		// the directory's, and the shared session's when there is one.
		let directory_value = |name: &str| {
			options
				.get(name)
				.cloned()
				.or_else(|| env(&server::Config::variable(name)))
				.map(|s| s.trim().to_owned())
				.filter(|s| !s.is_empty())
		};
		let session_value = |name: &str| {
			session
				.get(name)
				.cloned()
				.or_else(|| env(&crate::session::Config::variable(name)))
				.map(|s| s.trim().to_owned())
				.filter(|s| !s.is_empty())
		};
		let tor = if session_wanted {
			super::tor::Plan::read(&[&directory_value, &session_value], &env)?
		} else {
			super::tor::Plan::read(&[&directory_value], &env)?
		};
		let admission = super::admission::Config::read(&options, &env)?;
		let browser_admission = super::browser_admission::Config::read(&options, &env)?;
		for key in rooms_application::admission::Settings::OPTIONS {
			options.remove(&format!("http-{key}"));
			options.remove(&format!("browser-{key}"));
		}
		options.remove("http-admission-per-address");
		options.remove("http-trusted-proxies");
		let allow_origin = options.remove("allow-origin");
		let mut server_args: Vec<_> = options
			.into_iter()
			.map(|(key, value)| raw_options.remove(&key).unwrap_or_else(|| format!("--{key}={value}")))
			.collect();
		server_args.extend(declared);
		let relay_url = env("GLOWCAP_ROOMS_RELAY_URL")
			.map(|url| url.trim().to_owned())
			.filter(|url| !url.is_empty());
		if relay_url.is_none()
			&& let Some(option) = public_without_relay(&server_args, &session)
		{
			return Err(format!(
				"{option} names how peers dial the relay named with it; this server's own relay is dialed at --http-public"
			));
		}
		// The option and the environment name one fact, and the option wins.
		let relay = super::relay::Limits::read(|name| match name {
			"GLOWCAP_RELAY_ALLOW_ORIGINS" => allow_origin.clone().or_else(|| env(name)),
			_ => env(name),
		})?;
		let ice = super::ice::Config::read(&env)?;
		// Both peers are validated as they will be launched. This server's own
		// relay stands at the address the HTTP listener binds, known only
		// then, so validation stands a loopback relay in for it and `serve`
		// hands each peer the real one.
		let handed = PeerEnvironment {
			relay: listener_relay(
				relay_url.as_deref(),
				own_relay("ws://127.0.0.1/relay".into(), public.as_ref()),
			),
			tor: tor.as_ref().map(|plan| plan.endpoints.clone()),
		};
		let room = server::Config::parse(server_args.clone(), |key| handed.read(&env, key))
			.map_err(|e| e.to_string())?
			.ok_or("server configuration did not produce a launch")?;
		let session = session_wanted
			.then(|| {
				let args: Vec<String> = session.iter().map(|(key, value)| format!("--{key}={value}")).collect();
				session_config(args.clone(), |key| handed.read(&env, key))?;
				Ok::<_, String>(Session { args })
			})
			.transpose()?;
		Ok(Some(Self {
			bind,
			port,
			public,
			browser_assets,
			browser_admission,
			server,
			server_args,
			room,
			session,
			relay,
			relay_url,
			admission,
			ice,
			tor,
		}))
	}
}

/// What this front hands the peers it runs, the directory and the shared
/// session, in the environment each reads: the relay a relay door registers
/// at, and the private Tor an onion door publishes through.
pub(super) struct PeerEnvironment {
	pub relay: relay::Address,
	pub tor: Option<super::tor::Endpoints>,
}
impl PeerEnvironment {
	/// Every variable this front hands, with its value when the front has one.
	pub fn variables(&self) -> [(&'static str, Option<&str>); 4] {
		[
			("GLOWCAP_ROOMS_RELAY_URL", Some(self.relay.reach.as_str())),
			("GLOWCAP_ROOMS_RELAY_PUBLIC_URL", self.relay.public()),
			("GLOWCAP_ONION_SOCKS", self.tor.as_ref().map(|tor| tor.socks.as_str())),
			(
				"GLOWCAP_ONION_CONTROL",
				self.tor.as_ref().map(|tor| tor.control.as_str()),
			),
		]
	}
	/// Read `key` as a peer under this front does: what the front hands,
	/// else the environment.
	pub fn read(&self, env: impl Fn(&str) -> Option<String>, key: &str) -> Option<String> {
		self.variables()
			.into_iter()
			.find_map(|(name, value)| (name == key).then_some(value).flatten())
			.map(str::to_owned)
			.or_else(|| env(key))
	}
}

/// The option that names a public address for a relay a peer under this
/// front registers at without naming the relay, when one does. That peer
/// registers at this server's own relay, which browsers and peers dial at
/// `--http-public`'s relay, so a public address for it alone would be a
/// second answer to one question and leave the other peer dialing the
/// relay's bound address.
fn public_without_relay(server_args: &[String], session: &BTreeMap<String, String>) -> Option<String> {
	let names = |option: &str| server_args.iter().any(|arg| arg.starts_with(&format!("--{option}=")));
	if names("relay-public") && !names("relay") {
		return Some("--relay-public".into());
	}
	// A `--listen` declaration takes no public address: the directory refuses
	// one itself, so its relay door is dialed as its relay option says.
	(session.contains_key("relay-public") && !session.contains_key("relay")).then(|| "--session-relay-public".into())
}

/// This server's own relay: reached at `reach`, the `/relay` route of its
/// bound address, and dialed by browsers at `public`'s relay when one is
/// named, else where it is reached.
pub(super) fn own_relay(reach: String, public: Option<&url::Url>) -> relay::Address {
	relay::Address {
		dial: public.map(public_relay_url).unwrap_or_else(|| reach.clone()),
		reach,
	}
}

/// The relay the peers under this front register relay doors at: a relay the
/// operator named, as it is, else this server's `own`.
pub(super) fn listener_relay(named: Option<&str>, own: relay::Address) -> relay::Address {
	match named {
		Some(named) => relay::Address {
			reach: named.to_owned(),
			dial: named.to_owned(),
		},
		None => own,
	}
}

/// The shared session's configuration as it reads its options under this
/// front. `--help` is no session option, so a parse that refuses nothing
/// produces one.
pub(super) fn session_config(
	args: impl IntoIterator<Item = String>,
	read: impl Fn(&str) -> Option<String>,
) -> Result<crate::session::Config, String> {
	crate::session::Config::parse(args, read)
		.map_err(|error| error.to_string())?
		.ok_or_else(|| "session configuration did not produce a launch".to_owned())
}

/// The relay browsers reach at `public`: the same origin over WebSocket,
/// at the `/relay` route this server serves at its root.
pub(super) fn public_relay_url(public: &url::Url) -> String {
	let origin = public.origin().ascii_serialization();
	let scheme = if public.scheme() == "https" { "wss" } else { "ws" };
	let authority = origin
		.split_once("://")
		.map_or(origin.as_str(), |(_, authority)| authority);
	format!("{scheme}://{authority}/relay")
}

/// The refusal for an option given without its value, showing the form the
/// help text gives it, so the two cannot disagree.
pub(super) fn needs_value(key: &str) -> String {
	let prefix = format!("--{key}=");
	let form = HELP
		.split_whitespace()
		.find(|word| word.starts_with(&prefix))
		.map_or_else(|| format!("{prefix}<value>"), str::to_owned);
	format!("--{key} needs a value, as in {form}")
}

#[cfg(test)]
mod tests;
