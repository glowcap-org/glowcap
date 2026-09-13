//! PostgreSQL owns the current `room_lines` schema.
//! One session lease covers restore through shutdown. Each admitted effect
//! commits once, including whole-room eviction, edits and withdrawals.
use super::super::{config::PostgresConfig, error::Error};
use rooms_application::server::history::{Index, KeptLine, LINES_KEPT, LINES_KEPT_TOTAL, Persist};
use std::collections::BTreeMap;
use tokio_postgres::{Client, Statement};
mod connection;
use connection::{Connection, database, drive};

// All host owners of this database's room_lines table take this lease.
const LEASE: i64 = 0x524f_4f4d_5348_4953;
const SCHEMA: &str = "CREATE TABLE IF NOT EXISTS room_lines (
 seq bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 room text NOT NULL, from_nick text NOT NULL, said text NOT NULL, at_ms bigint NOT NULL,
 previews text NOT NULL DEFAULT '[]'
);
CREATE INDEX IF NOT EXISTS room_lines_room_seq ON room_lines (room, seq)";

pub(super) struct Backend {
	connection: Connection,
	statements: Statements,
}
struct Statements {
	append: Statement,
	trim: Statement,
	delete: Statement,
	insert_tail: Statement,
}
impl Statements {
	async fn prepare(client: &Client) -> Result<Self, Error> {
		Ok(Self {
			append: client
				.prepare("INSERT INTO room_lines (room, from_nick, said, at_ms, previews) VALUES ($1, $2, $3, $4, $5)")
				.await
				.map_err(database)?,
			trim: client
				.prepare(
					"DELETE FROM room_lines WHERE room = $1 AND seq < (
			 SELECT seq FROM room_lines WHERE room = $1 ORDER BY seq DESC LIMIT 1 OFFSET $2)",
				)
				.await
				.map_err(database)?,
			delete: client
				.prepare("DELETE FROM room_lines WHERE room = $1")
				.await
				.map_err(database)?,
			insert_tail: client
				.prepare(
					"INSERT INTO room_lines (room, from_nick, said, at_ms, previews)
			 SELECT $1, from_nick, said, at_ms, previews FROM unnest($2::text[], $3::text[], $4::bigint[], $5::text[])
			 WITH ORDINALITY AS tail(from_nick, said, at_ms, previews, position) ORDER BY position",
				)
				.await
				.map_err(database)?,
		})
	}
}
impl Backend {
	pub(super) async fn open(config: PostgresConfig) -> Result<(Self, Index), Error> {
		let mut connection = Connection::open(config).await?;
		let client = &mut connection.client;
		let (statements, index) = drive(&mut connection.wire, async {
			let row = client
				.query_one("SELECT pg_try_advisory_lock($1)", &[&LEASE])
				.await
				.map_err(database)?;
			if !row.try_get::<_, bool>(0).map_err(database)? {
				return Err(Error::History(
					"PostgreSQL room history is already held by another server".into(),
				));
			}
			let transaction = client.transaction().await.map_err(database)?;
			transaction.batch_execute(SCHEMA).await.map_err(database)?;
			let statements = Statements::prepare(transaction.client()).await?;
			// Bound both row count and field bytes before materializing results
			// in Rust. NULL means oversized state and is refused by try_get.
			let query = format!(
				"SELECT
			 CASE WHEN octet_length(room) <= {} THEN room END,
			 CASE WHEN octet_length(from_nick) <= {} THEN from_nick END,
			 CASE WHEN octet_length(said) <= {} THEN said END, at_ms,
			 CASE WHEN octet_length(previews) <= {} THEN previews END
			 FROM (SELECT * FROM room_lines ORDER BY seq DESC LIMIT {}) recent ORDER BY seq",
				rooms_application::server::document::MAX_DURABLE_ROOM * 4,
				rooms_application::room::inbox::MAX_NICK * 4,
				rooms_application::room::line::MAX_LINE_BYTES,
				rooms_application::open_graph::MAX_PREVIEWS * (rooms_application::open_graph::MAX_URL_BYTES + 4),
				LINES_KEPT_TOTAL + 1
			);
			let rows = transaction.query(&query, &[]).await.map_err(database)?;
			if rows.len() > LINES_KEPT_TOTAL {
				return Err(Error::History(format!(
					"PostgreSQL room history contains more than {LINES_KEPT_TOTAL} retained lines"
				)));
			}
			let mut rooms = BTreeMap::<String, Vec<KeptLine>>::new();
			for row in rows {
				let at: i64 = row.try_get(3).map_err(database)?;
				let text: String = row.try_get(2).map_err(database)?;
				let encoded_previews: String = row.try_get(4).map_err(database)?;
				let previews = rooms_application::open_graph::Selection::decode(&text, &encoded_previews)
					.map_err(|error| Error::History(error.to_string()))?;
				let line = KeptLine {
					from: row.try_get(1).map_err(database)?,
					text,
					at: u64::try_from(at)
						.map_err(|_| Error::History("PostgreSQL history has a negative timestamp".into()))?,
					previews,
				};
				rooms.entry(row.try_get(0).map_err(database)?).or_default().push(line);
			}
			let mut index = Index::default();
			for (room, lines) in rooms {
				index
					.restore_room(&room, lines)
					.map_err(|e| Error::History(e.to_string()))?;
				transaction
					.execute(&statements.trim, &[&room, &((LINES_KEPT - 1) as i64)])
					.await
					.map_err(database)?;
			}
			for room in index.take_evicted() {
				transaction
					.execute(&statements.delete, &[&room])
					.await
					.map_err(database)?;
			}
			transaction.commit().await.map_err(database)?;
			Ok((statements, index))
		})
		.await?;
		Ok((Self { connection, statements }, index))
	}
	pub(super) async fn persist(&mut self, change: Persist) -> Result<(), Error> {
		let client = &mut self.connection.client;
		let statements = &self.statements;
		drive(&mut self.connection.wire, async {
			let transaction = client.transaction().await.map_err(database)?;
			match change {
				Persist::Append { room, line, evicted } => {
					transaction
						.execute(
							&statements.append,
							&[
								&room,
								&line.from,
								&line.text,
								&(line.at as i64),
								&line.previews.encode(),
							],
						)
						.await
						.map_err(database)?;
					transaction
						.execute(&statements.trim, &[&room, &((LINES_KEPT - 1) as i64)])
						.await
						.map_err(database)?;
					if let Some(room) = evicted {
						transaction
							.execute(&statements.delete, &[&room])
							.await
							.map_err(database)?;
					}
				}
				Persist::Replace { room, tail } => {
					transaction
						.execute(&statements.delete, &[&room])
						.await
						.map_err(database)?;
					if !tail.is_empty() {
						let from: Vec<_> = tail.iter().map(|line| line.from.as_str()).collect();
						let text: Vec<_> = tail.iter().map(|line| line.text.as_str()).collect();
						let at: Vec<_> = tail.iter().map(|line| line.at as i64).collect();
						let previews: Vec<_> = tail.iter().map(|line| line.previews.encode()).collect();
						transaction
							.execute(&statements.insert_tail, &[&room, &from, &text, &at, &previews])
							.await
							.map_err(database)?;
					}
				}
			}
			transaction.commit().await.map_err(database)
		})
		.await
	}
	pub(super) async fn close(self) -> Result<(), Error> {
		drop(self.statements);
		self.connection.close().await
	}
}
