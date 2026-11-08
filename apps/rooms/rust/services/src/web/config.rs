//! The web command selects HTTP and supervision. Server options retain their
//! existing parser and environment, so both entrypoints validate one contract.
use crate::server;
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
	pub(super) session: Option<crate::session::Config>,
	pub(super) tor: Option<super::tor::Plan>,
	pub(super) ice: super::ice::Config,
	pub(super) relay: super::relay::Limits,
	/// The relay URL the supervised directory registers relay listeners at,
	/// when the operator named one. Otherwise the directory is handed this
	/// server's own relay once the HTTP address is known.
	pub(super) relay_url: Option<String>,
}
pub(super) enum BrowserAssets {
	Source(PathBuf),
	Prepared(PathBuf),
	Disabled,
}
pub const HELP: &str = concat!(
	"rooms-web [http-port] [room-port] [options]
  --http-bind=<host> --http-port=<port>  HTTP listener (default: 0.0.0.0:8080)
  --http-public=<url>  the address browsers reach this server at, named by every link it prints (default: http://localhost:<port>/, or GLOWCAP_ROOMS_HTTP_PUBLIC)
  --assets=<directory>  Rooms web source, or an artifact directory with --prepared (default: apps/rooms/web)
  --prepared  serve a prepared bundle without invoking browser build tools
  --no-browser-assets  serve Rooms endpoints without a browser bundle (development tooling)
  --server=<executable>  rooms-server binary (default: beside rooms-web)
  --transport=iroh|tcp|onion  supervised directory (default: iroh)
  --listen=<transport>[,<name>=<value>...]  also listen over another transport, as rooms-server; repeatable
      a relay listener registers at this server's own relay unless GLOWCAP_ROOMS_RELAY_URL or its relay option names another
  --state=<directory>  keep the directory identity and state across restarts
  --session-state=<directory>  also serve a durable shared workspace and print its use and management links
  --history --bind=<host> --announce-host=<host>
  --admin-listeners --diagnostics --operator --peering --irc --trace
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
					"http-bind" | "http-port" | "http-public" | "assets" | "server" | "session-state" | "allow-origin"
				) || key.starts_with("http-admission-")
					|| key.starts_with("browser-admission-");
				// `--allow-origin=` is a value, the empty list, as its help says.
				let empty_is_value = key == "allow-origin";
				if takes_value && (!option.contains('=') || (value.is_empty() && !empty_is_value)) {
					return Err(needs_value(key));
				}
				// Transport build variants supply a default before user arguments.
				// Preserve the web command's last-option-wins convention, except
				// for the origin list, where every value given is kept: dropping
				// one a person typed would refuse their page without a word.
				let value = match options.get(key) {
					Some(prior) if key == "allow-origin" && !prior.is_empty() && !value.is_empty() => {
						format!("{prior},{value}")
					}
					_ => value.to_owned(),
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
		let session = options
			.remove("session-state")
			.map(|state| {
				crate::session::Config::parse([format!("--state={state}")], &env)
					.map_err(|error| error.to_string())?
					.ok_or_else(|| "session configuration did not produce a launch".to_owned())
			})
			.transpose()?;
		options
			.entry("port".into())
			.or_insert_with(|| positional.get(1).cloned().unwrap_or_else(|| "9099".into()));
		let tor = super::tor::Plan::read(&options, &env)?;
		if let Some(tor) = &tor {
			for (key, value) in [("onion-socks", &tor.socks), ("onion-control", &tor.control)] {
				options.insert(key.into(), value.clone());
				raw_options.insert(key.into(), format!("--{key}={value}"));
			}
		}
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
		// The option and the environment name one fact, and the option wins.
		let relay = super::relay::Limits::read(|name| match name {
			"GLOWCAP_RELAY_ALLOW_ORIGINS" => allow_origin.clone().or_else(|| env(name)),
			_ => env(name),
		})?;
		let ice = super::ice::Config::read(&env)?;
		let room = server::Config::parse(server_args.clone(), env)
			.map_err(|e| e.to_string())?
			.ok_or("server configuration did not produce a launch")?;
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
mod tests {
	use super::{BrowserAssets, Config};
	use std::path::Path;

	fn parse(args: &[&str]) -> Config {
		Config::parse(args.iter().map(|arg| (*arg).to_owned()), |_| None)
			.unwrap()
			.unwrap()
	}

	#[test]
	fn http_policy_stays_at_its_owner_and_arguments_override_environment() {
		let config = Config::parse(
			[
				"--http-admission-rates=preview=2/10".into(),
				"--http-admission-per-address=true".into(),
			],
			|key| (key == "GLOWCAP_ROOMS_HTTP_ADMISSION_RATES").then(|| "preview=1/1".into()),
		)
		.unwrap()
		.unwrap();
		assert_eq!(
			config
				.admission
				.settings
				.profile()
				.rate(rooms_application::admission::Class::Preview)
				.burst(),
			2
		);
		assert!(config.admission.per_address);
		assert!(!config.server_args.iter().any(|s| s.starts_with("--http-admission")));
		assert!(config.admission.settings.summary().contains("admission-rates=argument"));
		assert!(Config::parse(["--http-admission-rows=0".into()], |_| None).is_err());
	}

	#[test]
	fn every_listen_declaration_reaches_the_directory() {
		let config = parse(&["--listen=noise-relay", "--transport=tcp", "--listen=noise-tcp,port=0"]);
		let declared: Vec<_> = config
			.server_args
			.iter()
			.filter(|arg| arg.starts_with("--listen="))
			.collect();
		assert_eq!(declared, ["--listen=noise-relay", "--listen=noise-tcp,port=0"]);
		assert_eq!(config.room.listen.len(), 2);
		assert!(config.relay_url.is_none());
		let refused = |args: &[&str]| {
			Config::parse(args.iter().map(|arg| (*arg).to_owned()), |_| None)
				.err()
				.expect("a refusal")
		};
		assert_eq!(
			refused(&["--listen"]),
			"--listen needs a value, as in --listen=<transport>[,<name>=<value>...]"
		);
		assert!(refused(&["--listen=iroh"]).contains("names the announced transport"));
		let config = Config::parse([], |key| {
			(key == "GLOWCAP_ROOMS_RELAY_URL").then(|| " wss://relay.example/relay ".into())
		})
		.unwrap()
		.unwrap();
		assert_eq!(config.relay_url.as_deref(), Some("wss://relay.example/relay"));
	}

	#[test]
	fn allowed_origins_come_from_the_option_over_the_environment_and_stay_out_of_server_args() {
		let env = |key: &str| (key == "GLOWCAP_RELAY_ALLOW_ORIGINS").then(|| "https://env.example".into());
		let config = Config::parse(["--allow-origin=https://glowcap.org,http://127.0.0.1:8093".into()], env)
			.unwrap()
			.unwrap();
		let origins: Vec<_> = config
			.relay
			.origins
			.iter()
			.map(|origin| origin.ascii_serialization())
			.collect();
		assert_eq!(origins, ["https://glowcap.org", "http://127.0.0.1:8093"]);
		assert!(!config.server_args.iter().any(|s| s.contains("allow-origin")));
		let config = Config::parse([], env).unwrap().unwrap();
		assert_eq!(config.relay.origins.len(), 1);
		// The empty value the help names: no page but this server's own.
		let config = Config::parse(["--allow-origin=".into()], env).unwrap().unwrap();
		assert!(config.relay.origins.is_empty() && config.relay.pages.is_empty());
		assert_eq!(
			Config::parse(["--allow-origin".into()], |_| None).err().unwrap(),
			"--allow-origin needs a value, as in --allow-origin=<origin|page,...>"
		);
		assert_eq!(
			Config::parse(["--session-state".into()], |_| None).err().unwrap(),
			"--session-state needs a value, as in --session-state=<directory>"
		);
		// A page's own address admits its origin, and is the page the banner
		// links to. A path without its final `/` names no page exactly.
		let config = Config::parse(
			["--allow-origin=https://glowcap.org/rooms/app/,http://127.0.0.1:8093".into()],
			|_| None,
		)
		.unwrap()
		.unwrap();
		assert_eq!(config.relay.origins.len(), 2);
		assert_eq!(config.relay.origins[0].ascii_serialization(), "https://glowcap.org");
		let pages: Vec<_> = config.relay.pages.iter().map(url::Url::as_str).collect();
		assert_eq!(pages, ["https://glowcap.org/rooms/app/"]);
		// The option repeated keeps every value, in order, the same as one list.
		let repeated = Config::parse(
			[
				"--allow-origin=https://glowcap.org/rooms/app/".into(),
				"--allow-origin=http://127.0.0.1:8093".into(),
			],
			|_| None,
		)
		.unwrap()
		.unwrap();
		assert_eq!(repeated.relay.origins, config.relay.origins);
		assert_eq!(repeated.relay.pages, config.relay.pages);
		// An empty value among others adds nothing, and alone it allows none.
		let mixed = Config::parse(
			["--allow-origin=".into(), "--allow-origin=http://127.0.0.1:8093".into()],
			|_| None,
		)
		.unwrap()
		.unwrap();
		assert_eq!(mixed.relay.origins.len(), 1);
		assert!(Config::parse(["--allow-origin=https://glowcap.org/rooms/app".into()], |_| None).is_err());
		// A page at the root of its origin is written with its `/`, and a bare
		// origin without one, so the two are told apart as written.
		let config = Config::parse(
			["--allow-origin=https://pages.example/,https://origin.example".into()],
			|_| None,
		)
		.unwrap()
		.unwrap();
		let pages: Vec<_> = config.relay.pages.iter().map(url::Url::as_str).collect();
		assert_eq!(pages, ["https://pages.example/"]);
		assert_eq!(
			config.relay.listed,
			["https://pages.example/", "https://origin.example"]
		);
	}

	#[test]
	fn the_public_address_is_read_exactly_from_arguments_or_environment_and_stays_out_of_server_args() {
		let config = Config::parse(["--http-public=https://rooms.example/".into()], |_| None)
			.unwrap()
			.unwrap();
		assert_eq!(
			config.public.as_ref().map(url::Url::as_str),
			Some("https://rooms.example/")
		);
		assert!(!config.server_args.iter().any(|s| s.contains("http-public")));
		let config = Config::parse([], |key| {
			(key == "GLOWCAP_ROOMS_HTTP_PUBLIC").then(|| "https://rooms.example/app/".into())
		})
		.unwrap()
		.unwrap();
		assert_eq!(
			config.public.as_ref().map(url::Url::as_str),
			Some("https://rooms.example/app/")
		);
		assert!(parse(&[]).public.is_none());
		// A bare origin is the address with the path `/`, as the URL standard
		// reads it, and a path without its final `/` is refused whole.
		let config = Config::parse(["--http-public=https://rooms.example".into()], |_| None)
			.unwrap()
			.unwrap();
		assert_eq!(
			config.public.as_ref().map(url::Url::as_str),
			Some("https://rooms.example/")
		);
		for refused in [
			"https://rooms.example/app",
			"ws://rooms.example/",
			"https://rooms.example/?x",
			"rooms.example/",
		] {
			let error = Config::parse([format!("--http-public={refused}")], |_| None)
				.err()
				.expect("refused");
			assert!(error.contains("--http-public") && error.contains(refused), "{error}");
		}
		assert_eq!(
			Config::parse(["--http-public".into()], |_| None)
				.err()
				.expect("refused"),
			"--http-public needs a value, as in --http-public=<url>"
		);
	}
	#[test]
	fn trusted_proxies_are_read_from_arguments_or_environment_and_stay_out_of_server_args() {
		let config = Config::parse(["--http-trusted-proxies=10.0.0.0/8, fd00::1".into()], |_| None)
			.unwrap()
			.unwrap();
		assert_eq!(config.admission.trusted_proxies.len(), 2);
		assert!(!config.server_args.iter().any(|s| s.contains("trusted-proxies")));
		let config = Config::parse([], |key| {
			(key == "GLOWCAP_ROOMS_HTTP_TRUSTED_PROXIES").then(|| "127.0.0.1".into())
		})
		.unwrap()
		.unwrap();
		assert_eq!(config.admission.trusted_proxies.len(), 1);
		assert_eq!(parse(&[]).admission.trusted_proxies.len(), 0);
		let error = Config::parse(["--http-trusted-proxies=10.0.0.0/40".into()], |_| None)
			.err()
			.unwrap();
		assert!(error.contains("10.0.0.0/40"), "{error}");
	}

	#[test]
	fn browser_asset_mode_is_explicit() {
		assert!(
			matches!(parse(&[]).browser_assets, BrowserAssets::Source(path) if path == Path::new("apps/rooms/web"))
		);
		assert!(
			matches!(parse(&["--assets=prepared", "--prepared"]).browser_assets, BrowserAssets::Prepared(path) if path == Path::new("prepared"))
		);
		assert!(matches!(
			parse(&["--no-browser-assets"]).browser_assets,
			BrowserAssets::Disabled
		));
	}

	#[test]
	fn disabled_assets_cannot_hide_an_asset_configuration() {
		for args in [
			["--no-browser-assets", "--assets=prepared"].as_slice(),
			["--no-browser-assets", "--prepared"].as_slice(),
		] {
			assert!(Config::parse(args.iter().map(|arg| (*arg).to_owned()), |_| None).is_err());
		}
	}
}
