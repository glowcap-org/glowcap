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
pub struct PostgresConfig(pub(in crate::room_server) Box<tokio_postgres::Config>);
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
}
