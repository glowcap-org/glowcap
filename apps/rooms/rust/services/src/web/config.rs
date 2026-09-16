//! The web command selects HTTP and supervision. Server options retain their
//! existing parser and environment, so both entrypoints validate one contract.
use crate::server;
use std::{collections::BTreeMap, path::PathBuf};

pub struct Config {
	pub bind: String,
	pub port: u16,
	pub(super) browser_assets: BrowserAssets,
	pub server: PathBuf,
	pub server_args: Vec<String>,
	pub room: server::Config,
	pub(super) tor: Option<super::tor::Plan>,
	pub(super) ice: super::ice::Config,
	pub(super) relay: super::relay::Limits,
}
pub(super) enum BrowserAssets {
	Source(PathBuf),
	Prepared(PathBuf),
	Disabled,
}
pub const HELP: &str = "rooms-web [http-port] [room-port] [options]
  --http-bind=<host> --http-port=<port>  HTTP listener (default: 0.0.0.0:8000)
  --assets=<directory>  Rooms web source, or an artifact directory with --prepared (default: apps/rooms/web)
  --prepared  serve a prepared bundle without invoking browser build tools
  --no-browser-assets  serve native Rooms endpoints without a browser bundle (development tooling)
  --server=<executable>  rooms-server binary (default: beside rooms-web)
  --transport=iroh|tcp|onion  supervised directory (default: iroh)
  --state=<directory>  keep the directory identity and state across restarts
  --history --storage=<destination> --bind=<host> --announce-host=<host>
  --admin-listeners --diagnostics --operator --peering --irc --trace
Server options and GLOWCAP_ROOMS_* variables have the same meaning as rooms-server.
rooms-web --check-ready[=http://host:port]  check directory and browser assets (5 second deadline)
rooms-web --locator[=http://host:port]  print the running directory locator
rooms-web --ui-version[=http://host:port]  print the running browser revision
Status reads default to http://127.0.0.1:8000, or GLOWCAP_ROOMS_HTTP_PORT.
rooms-web --prepare[=<output-directory>] [--assets=<source-directory>]  build self-contained browser assets
Preparation defaults to zig-out/rooms-web; serve its current directory with --prepared.
";
impl Config {
	pub fn parse(
		args: impl IntoIterator<Item = String>,
		env: impl Fn(&str) -> Option<String>,
	) -> Result<Option<Self>, String> {
		let mut options = BTreeMap::new();
		let mut positional = Vec::new();
		let mut raw_options = BTreeMap::new();
		for arg in args {
			if arg == "--help" || arg == "-h" {
				return Ok(None);
			}
			if let Some(option) = arg.strip_prefix("--") {
				let (key, value) = option.split_once('=').unwrap_or((option, "1"));
				if matches!(key, "http-bind" | "http-port" | "assets" | "server")
					&& (!option.contains('=') || value.is_empty())
				{
					return Err(format!("--{key} requires a nonempty value"));
				}
				// Transport build variants supply a default before user arguments.
				// Preserve the web command's last-option-wins convention.
				options.insert(key.to_owned(), value.to_owned());
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
			.unwrap_or_else(|| "8000".into())
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
		let server_args: Vec<_> = options
			.into_iter()
			.map(|(key, value)| raw_options.remove(&key).unwrap_or_else(|| format!("--{key}={value}")))
			.collect();
		let relay = super::relay::Limits::read(&env)?;
		let ice = super::ice::Config::read(&env)?;
		let room = server::Config::parse(server_args.clone(), env)
			.map_err(|e| e.to_string())?
			.ok_or("server configuration did not produce a launch")?;
		Ok(Some(Self {
			bind,
			port,
			browser_assets,
			server,
			server_args,
			room,
			relay,
			ice,
			tor,
		}))
	}
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
