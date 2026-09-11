//! Standalone archive options. Parse everything before acquiring durable custody.
pub use crate::serving::Transport;
use std::{collections::BTreeMap, path::PathBuf};
pub struct Config {
	pub state: PathBuf,
	pub transport: Transport,
}
pub const HELP: &str = "rooms-archive --state=<directory> [--transport=iroh|tcp|onion]\n  --reachability=discovery|direct  iroh reachability (default: discovery)\n  --bind=<host> --port=<port> --announce-host=<host>  TCP listener options\n  --onion-socks=<endpoint> --onion-control=<endpoint>  running Tor endpoints (or GLOWCAP_ONION_SOCKS/CONTROL)\n  --port=<port>  onion local forward port; 0 chooses an ephemeral loopback port\n  --onion-forward=<absolute-path>  bind a Unix forwarding socket instead (requires --port=0)\nOptions override GLOWCAP_ARCHIVE_* environment variables. TCP defaults to 127.0.0.1:0.\n";
impl Config {
	pub fn parse(
		args: impl IntoIterator<Item = String>,
		env: impl Fn(&str) -> Option<String>,
	) -> Result<Option<Self>, String> {
		let mut named = BTreeMap::new();
		for arg in args {
			if arg == "--help" || arg == "-h" {
				return Ok(None);
			}
			let (key, value) = arg
				.strip_prefix("--")
				.and_then(|s| s.split_once('='))
				.ok_or("options use --name=value")?;
			if key != "state" && !Transport::OPTIONS.contains(&key) {
				return Err(format!("unknown archive option: --{key}"));
			}
			if named.insert(key.to_owned(), value.to_owned()).is_some() {
				return Err(format!("repeated archive option: --{key}"));
			}
		}
		let value = |key: &str| {
			named.get(key).cloned().or_else(|| {
				env(&format!("GLOWCAP_ARCHIVE_{}", key.replace('-', "_").to_uppercase()))
					.map(|s| s.trim().to_owned())
					.filter(|s| !s.is_empty())
			})
		};
		let state = value("state")
			.filter(|s| !s.is_empty())
			.ok_or("name durable storage with --state=<directory> or GLOWCAP_ARCHIVE_STATE")?;
		let transport = Transport::parse(value, &env, "archive")?;
		Ok(Some(Self {
			state: state.into(),
			transport,
		}))
	}
}
