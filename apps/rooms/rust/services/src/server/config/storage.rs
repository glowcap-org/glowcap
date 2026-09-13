//! A destination is parsed before acquiring server custody. Database secrets
//! never participate in Debug or diagnostics, including malformed URLs.
use super::Error;
use std::{fmt, path::PathBuf, time::Duration};
use tokio_postgres::config::Host;

#[derive(Clone, Debug)]
pub enum Storage {
	Files(PathBuf),
	Postgres(PostgresConfig),
}

#[derive(Clone)]
pub struct PostgresConfig(pub(in crate::server) Box<tokio_postgres::Config>);
impl fmt::Debug for PostgresConfig {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		f.write_str("PostgresConfig { credentials: [redacted] }")
	}
}
impl Storage {
	pub fn parse(value: &str) -> Result<Self, Error> {
		if value.is_empty() {
			return Err(Error::refused("--storage takes a nonempty destination"));
		}
		let Some((scheme, _)) = value.split_once("://") else {
			return Ok(Self::Files(value.into()));
		};
		if !matches!(scheme, "postgres" | "postgresql") {
			return Err(Error::refused(
				"unknown storage scheme: use a file directory or postgres:// URL",
			));
		}
		let mut config: tokio_postgres::Config = value.parse().map_err(|_| {
			Error::refused("invalid PostgreSQL history URL; expected postgres://user:password@host/database")
		})?;
		if config.get_hosts().is_empty()
			|| config
				.get_hosts()
				.iter()
				.any(|host| matches!(host, Host::Tcp(name) if name.is_empty()))
		{
			return Err(Error::refused("the history database URL names no host"));
		}
		if config.get_user().is_none_or(str::is_empty) {
			return Err(Error::refused("the history database URL names no user"));
		}
		if config.get_dbname().is_none_or(str::is_empty) {
			return Err(Error::refused("the history database URL names no database"));
		}
		config
			.application_name("rooms-server")
			.connect_timeout(Duration::from_secs(30));
		Ok(Self::Postgres(PostgresConfig(Box::new(config))))
	}

	/// Take the database password from a file rather than the URL.
	///
	/// A deployment keeps its secret in a file the orchestrator mounts (a
	/// Docker secret, a systemd credential) so the password never appears in
	/// a command line, a process environment, or a container's inspectable
	/// configuration. The URL then names user, host, and database only. A URL
	/// that already carries a password beside a file is two authorities for
	/// one fact and is refused; a file for a file destination is refused too,
	/// because nothing would read it. The file's trailing newline is not part
	/// of the password.
	pub fn with_password_file(self, path: &std::path::Path) -> Result<Self, Error> {
		let Self::Postgres(PostgresConfig(mut config)) = self else {
			return Err(Error::refused(
				"--storage-password-file needs a postgres:// storage destination",
			));
		};
		if config.get_password().is_some() {
			return Err(Error::refused(
				"the history database URL already carries a password; drop it or --storage-password-file",
			));
		}
		let password = std::fs::read_to_string(path)
			.map_err(|e| Error::refused(format!("--storage-password-file could not be read: {e}")))?;
		let password = password.trim_end_matches(['\n', '\r']);
		if password.is_empty() {
			return Err(Error::refused("--storage-password-file names an empty file"));
		}
		config.password(password);
		Ok(Self::Postgres(PostgresConfig(config)))
	}
}
