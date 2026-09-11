//! The database socket is polled alongside its current operation, never in
//! a detached task. Dropping this owner drops the socket and its session lock.
use super::{Error, PostgresConfig};
use std::{future::Future, pin::Pin, time::Duration};
use tokio_postgres::{config::SslMode, Client, NoTls};
use tokio_postgres_rustls::MakeRustlsConnect;

const DEADLINE: Duration = Duration::from_secs(30);
type Wire = Pin<Box<dyn Future<Output = Result<(), tokio_postgres::Error>> + Send>>;
pub(super) struct Connection {
	pub client: Client,
	pub wire: Wire,
}
impl Connection {
	pub async fn open(config: PostgresConfig) -> Result<Self, Error> {
		let open = async {
			if config.0.get_ssl_mode() == SslMode::Disable {
				let (client, wire) = config.0.connect(NoTls).await.map_err(database)?;
				Ok(Self {
					client,
					wire: Box::pin(wire),
				})
			} else {
				let tls = crate::tls::system_config()
					.await
					.map_err(|e| Error::History(format!("PostgreSQL {e}")))?;
				let (client, wire) = config.0.connect(MakeRustlsConnect::new(tls)).await.map_err(database)?;
				Ok(Self {
					client,
					wire: Box::pin(wire),
				})
			}
		};
		tokio::time::timeout(DEADLINE, open)
			.await
			.map_err(|_| Error::History("PostgreSQL history connection timed out".into()))?
	}
	pub async fn close(self) -> Result<(), Error> {
		drop(self.client);
		tokio::time::timeout(DEADLINE, self.wire)
			.await
			.map_err(|_| Error::History("PostgreSQL history shutdown timed out".into()))?
			.map_err(database)
	}
}

pub(super) async fn drive<T>(wire: &mut Wire, work: impl Future<Output = Result<T, Error>>) -> Result<T, Error> {
	tokio::select! {
		result = work => result,
		ended = wire => Err(match ended {
			Ok(()) => Error::History("PostgreSQL history connection ended during an operation".into()),
			Err(error) => database(error),
		}),
		_ = tokio::time::sleep(DEADLINE) => Err(Error::History("PostgreSQL history operation timed out; its transaction will not be retried".into())),
	}
}

pub(super) fn database(error: tokio_postgres::Error) -> Error {
	// Database DETAIL/CONTEXT may contain a row or a credential. SQLSTATE is
	// enough to identify a refusal without copying server-controlled secrets.
	match error.code() {
		Some(code) => Error::History(format!("PostgreSQL history refused (SQLSTATE {})", code.code())),
		None => Error::History(format!("PostgreSQL history: {error}")),
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::room_server::config::Storage;
	use tokio::{io::AsyncReadExt, net::TcpListener};

	#[tokio::test(start_paused = true)]
	async fn connection_deadline_closes_an_unanswered_database_startup() {
		tokio::task::LocalSet::new()
			.run_until(async {
				let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
				let Storage::Postgres(config) = Storage::parse(&format!(
					"postgresql://synthetic:synthetic@127.0.0.1:{}/postgres?sslmode=disable",
					listener.local_addr().unwrap().port()
				))
				.unwrap() else {
					unreachable!()
				};
				let task = tokio::task::spawn_local(Connection::open(config));
				let (mut socket, _) = listener.accept().await.unwrap();
				let mut bytes = [0; 4096];
				assert!(socket.read(&mut bytes).await.unwrap() > 0);
				tokio::time::advance(DEADLINE).await;
				let error = task.await.unwrap().err().expect("connection deadline").to_string();
				assert!(error.contains("connection timed out"));
				while socket.read(&mut bytes).await.unwrap() != 0 {}
			})
			.await;
	}
}
