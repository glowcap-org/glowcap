//! Room server options. Everything is parsed before durable custody is
//! acquired, so a refused option never leaves a lock or a half-written
//! document behind. The names are the ones the deployment already sets:
//! every option may come from `GLOWCAP_ROOMS_<NAME>`.
use super::{error::Error, operations::Asked};
pub use crate::serving::Transport;
mod storage;
use std::{collections::BTreeMap, path::PathBuf};
pub use storage::{PostgresConfig, Storage};

pub struct Config {
	/// Where the server document, its history, and its lock live. Without
	/// one the server is process-local: a fresh identity each start, and
	/// nothing kept past it.
	pub state: Option<PathBuf>,
	pub transport: Transport,
	/// Whether listed rooms keep their last lines.
	pub history: bool,
	/// Where kept lines persist: a file directory or PostgreSQL database.
	/// Naming one turns history on. With history on and no destination, the
	/// state directory keeps them, or memory when there is none.
	pub storage: Option<Storage>,
	/// The boot capabilities to mint and publish.
	pub asked: Asked,
	/// The loopback port the live timeline endpoint binds while `viz` is
	/// asked; zero takes an ephemeral one.
	pub viz_port: u16,
}

/// The timeline endpoint's port when nothing overrides it.
pub const VIZ_PORT: u16 = 9300;

pub const HELP: &str =
	"rooms-server [--state=<directory>] [--transport=iroh|tcp|onion] [--history] [--storage=<directory|postgres-url>]
  --state=<directory>  keep the server document, history, and operator choices here across restarts
  --history  keep the last lines of listed rooms
  --storage=<directory|postgres-url>  keep lines in files or a PostgreSQL database
  --reachability=discovery|direct  iroh reachability (default: discovery)
  --bind=<host> --port=<port> --announce-host=<host>  TCP listener options
  --onion-socks=<endpoint> --onion-control=<endpoint>  running Tor endpoints (or GLOWCAP_ONION_SOCKS/CONTROL)
  --port=<port>  onion local forward port; 0 chooses an ephemeral loopback port
  --onion-forward=<absolute-path>  bind a Unix forwarding socket instead (requires --port=0)
  --admin-listeners --diagnostics --operator --peering --irc --viz  mint an operator capability and print its swiss
  --viz-port=<port>  the loopback port the live timeline endpoint binds (default: 9300; 0 takes any)
Options override GLOWCAP_ROOMS_* environment variables. TCP defaults to 127.0.0.1:0.
rooms-server --capabilities[=<state-directory>]  print kept operator capabilities without starting a server
The directory defaults to GLOWCAP_ROOMS_STATE. Kept capabilities may be disabled in the current server.
";

/// The options beyond the transport's own that take a value.
const KEYS: &[&str] = &["state", "storage", "viz-port"];
/// The options that are flags: present, or `1`/`true`/`yes` in the environment.
const FLAGS: &[&str] = &[
	"history",
	"admin-listeners",
	"diagnostics",
	"operator",
	"peering",
	"irc",
	"viz",
];

impl Config {
	/// `None` means help was asked for. An argument wins over the environment.
	pub fn parse(
		args: impl IntoIterator<Item = String>,
		env: impl Fn(&str) -> Option<String>,
	) -> Result<Option<Self>, Error> {
		let mut named = BTreeMap::new();
		for arg in args {
			if arg == "--help" || arg == "-h" {
				return Ok(None);
			}
			let Some(option) = arg.strip_prefix("--") else {
				return Err(Error::refused("options use --name=value"));
			};
			let (key, value) = option.split_once('=').unwrap_or((option, "1"));
			if !KEYS.contains(&key) && !FLAGS.contains(&key) && !Transport::OPTIONS.contains(&key) {
				return Err(Error::refused(format!("unknown server option: --{key}")));
			}
			if !FLAGS.contains(&key) && !option.contains('=') {
				return Err(Error::refused(format!("--{key} takes a value")));
			}
			if named.insert(key.to_owned(), value.to_owned()).is_some() {
				return Err(Error::refused(format!("repeated server option: --{key}")));
			}
		}
		let value = |key: &str| {
			named.get(key).cloned().or_else(|| {
				env(&format!("GLOWCAP_ROOMS_{}", key.replace('-', "_").to_uppercase()))
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
		let transport = Transport::parse(value, &env, "server").map_err(Error::refused)?;
		let storage = value("storage").map(|value| Storage::parse(&value)).transpose()?;
		let history = flag("history")?.unwrap_or(storage.is_some());
		let asked = Asked {
			admin_listeners: flag("admin-listeners")?.unwrap_or(false),
			diagnostics: flag("diagnostics")?.unwrap_or(false),
			operator: flag("operator")?.unwrap_or(false),
			peering: flag("peering")?.unwrap_or(false),
			irc: flag("irc")?.unwrap_or(false),
			viz: flag("viz")?.unwrap_or(false),
		};
		let viz_port = match value("viz-port") {
			None => VIZ_PORT,
			Some(port) => port
				.parse::<u16>()
				.map_err(|_| Error::refused("--viz-port must be an integer from 0 through 65535"))?,
		};
		Ok(Some(Self {
			state: value("state").map(PathBuf::from),
			transport,
			history,
			storage,
			asked,
			viz_port,
		}))
	}
	/// Explicit storage wins over the state directory. With neither, history
	/// lives in memory. The file destination includes the `history/` child.
	pub fn history_storage(&self) -> Option<Storage> {
		if !self.history {
			return None;
		}
		match &self.storage {
			Some(Storage::Postgres(config)) => Some(Storage::Postgres(config.clone())),
			Some(Storage::Files(root)) => Some(Storage::Files(root.join("history"))),
			None => self.state.as_ref().map(|root| Storage::Files(root.join("history"))),
		}
	}
}
