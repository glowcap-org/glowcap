//! Standalone session options. Everything is parsed before durable custody is
//! acquired, so a refused option never leaves a lock or a half-written state.
use super::error::Error;
pub use crate::serving::Transport;
use std::{collections::BTreeMap, path::PathBuf};

pub struct Config {
	pub state: PathBuf,
	pub transport: Transport,
	pub checkpoint: Option<PathBuf>,
	pub readiness_file: Option<PathBuf>,
	/// The rendezvous relay this peer dials browser members through when a
	/// direct partner advertises a relay route.
	pub relay_url: Option<String>,
}

pub const HELP: &str = "rooms-session --state=<directory> [--transport=iroh|tcp|onion]
  --checkpoint=<Rooms JSON>  adopt a workspace or session document on a new peer
  --readiness-file=<path>  write the administrator sturdyref (default: <state>/admin.sturdyref)
  --reachability=discovery|direct  iroh reachability (default: discovery)
  --bind=<host> --port=<port> --announce-host=<host>  TCP listener options
  --onion-socks=<endpoint> --onion-control=<endpoint>  running Tor endpoints (or GLOWCAP_ONION_SOCKS/CONTROL)
  --port=<port>  onion local forward port; 0 chooses an ephemeral loopback port
  --onion-forward=<absolute-path>  bind a Unix forwarding socket instead (requires --port=0)
  --relay-url=<url>  dial browser members through this rendezvous relay
Options override GLOWCAP_ROOMS_SESSION_* environment variables. TCP defaults to 127.0.0.1:0.
rooms-session --check-ready=<path>  print the sturdyref a running peer wrote to its readiness file, or exit nonzero
";

/// The options beyond the transport's own.
const KEYS: &[&str] = &["state", "checkpoint", "readiness-file", "relay-url"];

impl Config {
	/// `None` means help was asked for. Every option may also come from
	/// `GLOWCAP_ROOMS_SESSION_<NAME>`; an argument wins over the environment.
	pub fn parse(
		args: impl IntoIterator<Item = String>,
		env: impl Fn(&str) -> Option<String>,
	) -> Result<Option<Self>, Error> {
		let mut named = BTreeMap::new();
		for arg in args {
			if arg == "--help" || arg == "-h" {
				return Ok(None);
			}
			let (key, value) = arg
				.strip_prefix("--")
				.and_then(|s| s.split_once('='))
				.ok_or_else(|| Error::refused("options use --name=value"))?;
			if !KEYS.contains(&key) && !Transport::OPTIONS.contains(&key) {
				return Err(Error::refused(format!("unknown session option: --{key}")));
			}
			if named.insert(key.to_owned(), value.to_owned()).is_some() {
				return Err(Error::refused(format!("repeated session option: --{key}")));
			}
		}
		let value = |key: &str| {
			named.get(key).cloned().or_else(|| {
				env(&format!(
					"GLOWCAP_ROOMS_SESSION_{}",
					key.replace('-', "_").to_uppercase()
				))
				.map(|s| s.trim().to_owned())
				.filter(|s| !s.is_empty())
			})
		};
		let state = value("state").filter(|s| !s.is_empty()).ok_or_else(|| {
			Error::refused("name durable storage with --state=<directory> or GLOWCAP_ROOMS_SESSION_STATE")
		})?;
		let transport = Transport::parse(value, &env, "session").map_err(Error::refused)?;
		Ok(Some(Self {
			state: state.into(),
			transport,
			checkpoint: value("checkpoint").filter(|s| !s.is_empty()).map(Into::into),
			readiness_file: value("readiness-file").filter(|s| !s.is_empty()).map(Into::into),
			relay_url: value("relay-url"),
		}))
	}
	pub fn readiness_path(&self) -> PathBuf {
		self.readiness_file
			.clone()
			.unwrap_or_else(|| self.state.join("admin.sturdyref"))
	}
}
