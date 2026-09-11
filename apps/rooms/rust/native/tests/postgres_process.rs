#![cfg(feature = "service")]
//! Opt-in database proof through the actual server binary. The supplied URL
//! must name a disposable PostgreSQL database. TLS scenarios use the repository
//! test CA, also supplied to the child through SSL_CERT_FILE.
//! Each run creates its own schema and removes exactly that schema afterward.
use glowcap::{tcp, ConnectOptions, PendingWork, Runtime, RuntimeConfig};
use rooms_glowcap::client::{
	directory::Directory,
	room::{Room, SubscribeOptions},
	Client,
};
use rooms_native::client::Deadline;
use std::{
	io::{BufRead, BufReader},
	process::{Child, Command, Stdio},
	sync::mpsc,
	time::{Duration, Instant},
};

struct Process(Child);
impl Drop for Process {
	fn drop(&mut self) {
		let _ = self.0.kill();
		let _ = self.0.wait();
	}
}
impl Process {
	fn start(url: &str) -> Self {
		Self::start_with_trust(url, None)
	}
	fn start_with_trust(url: &str, trust: Option<&str>) -> Self {
		let mut command = Command::new(
			std::env::var_os("GLOWCAP_ROOMS_SERVER_TEST_BIN")
				.unwrap_or_else(|| env!("CARGO_BIN_EXE_rooms-server").into()),
		);
		for (key, _) in std::env::vars_os() {
			if key.to_string_lossy().starts_with("GLOWCAP_ROOMS_") {
				command.env_remove(key);
			}
		}
		if let Some(trust) = trust {
			command
				.env("SSL_CERT_FILE", trust)
				.env("SSL_CERT_DIR", "/nonexistent-rooms-test-trust");
		}
		Self(
			command
				.args(["--transport=tcp", "--port=0"])
				.env("GLOWCAP_ROOMS_STORAGE", url)
				.stdout(Stdio::piped())
				.stderr(Stdio::piped())
				.spawn()
				.unwrap(),
		)
	}
	fn ready(&mut self) -> String {
		let stdout = self.0.stdout.take().unwrap();
		let (send, receive) = mpsc::sync_channel(1);
		std::thread::spawn(move || {
			let _ = send.send(BufReader::new(stdout).lines().next());
		});
		let line = receive
			.recv_timeout(Duration::from_secs(15))
			.expect("server announce deadline")
			.expect("server became ready")
			.unwrap();
		let port = line.strip_prefix("ROOMS-SERVER-LISTENING ").unwrap().parse().unwrap();
		glowcap::format_locator_uri(&tcp::locator("127.0.0.1", port)).unwrap()
	}
	fn finish(&mut self, success: bool) -> String {
		let end = Instant::now() + Duration::from_secs(10);
		loop {
			if let Some(status) = self.0.try_wait().unwrap() {
				assert_eq!(status.success(), success);
				break;
			}
			assert!(Instant::now() < end, "server termination deadline");
			std::thread::sleep(Duration::from_millis(5));
		}
		let mut stderr = String::new();
		std::io::Read::read_to_string(&mut self.0.stderr.take().unwrap(), &mut stderr).unwrap();
		stderr
	}
	fn stop(&mut self) {
		assert!(Command::new("/bin/kill")
			.args(["-TERM", &self.0.id().to_string()])
			.status()
			.unwrap()
			.success());
		self.finish(true);
	}
}

#[test]
fn shutdown_during_database_startup_retires_the_socket_without_readiness() {
	use std::io::Read;
	let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
	listener.set_nonblocking(true).unwrap();
	let url = format!(
		"postgresql://synthetic:synthetic@127.0.0.1:{}/postgres?sslmode=disable",
		listener.local_addr().unwrap().port()
	);
	let mut server = Process::start(&url);
	let deadline = Instant::now() + Duration::from_secs(5);
	let mut socket = loop {
		match listener.accept() {
			Ok((socket, _)) => break socket,
			Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
				assert!(Instant::now() < deadline, "database dial deadline");
				std::thread::sleep(Duration::from_millis(5));
			}
			Err(error) => panic!("database accept failed: {error}"),
		}
	};
	socket.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
	let mut length = [0; 4];
	socket.read_exact(&mut length).unwrap();
	let length = u32::from_be_bytes(length) as usize;
	assert!((8..4096).contains(&length));
	let mut startup = vec![0; length - 4];
	socket.read_exact(&mut startup).unwrap();
	assert!(Command::new("/bin/kill")
		.args(["-TERM", &server.0.id().to_string()])
		.status()
		.unwrap()
		.success());
	let mut byte = [0];
	assert_eq!(
		socket
			.read(&mut byte)
			.expect("shutdown must close the pending database socket"),
		0
	);
	assert!(server.finish(true).is_empty());
	assert!(BufReader::new(server.0.stdout.take().unwrap()).lines().next().is_none());
}

async fn member(location: &str) -> (Runtime, Client<Deadline>, Directory<Deadline>) {
	let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.unwrap();
	let session = runtime
		.connect(&glowcap::parse_locator(location).unwrap(), ConnectOptions::default())
		.await
		.unwrap();
	let client = Client::new(session, Deadline);
	let directory = Directory::fetch(client.clone()).await.unwrap();
	(runtime, client, directory)
}
async fn join(client: &Client<Deadline>, directory: &Directory<Deadline>, name: &str) -> Room<Deadline> {
	let (room, _messages) = Room::subscribe(
		client.clone(),
		directory.open(name).await.unwrap(),
		"Alice",
		SubscribeOptions::default(),
	)
	.await
	.unwrap();
	room
}

#[tokio::test]
#[ignore = "requires GLOWCAP_ROOMS_STORAGE_LIVE_URL for a disposable PostgreSQL database"]
async fn postgres_server_process_restores_edits_withdrawals_and_exclusive_custody() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(60), scenario())
				.await
				.expect("PostgreSQL process scenario deadline");
		})
		.await;
}
async fn scenario() {
	let url = std::env::var("GLOWCAP_ROOMS_STORAGE_LIVE_URL").expect("a disposable database URL");
	let (database, wire) = tokio_postgres::connect(&url, database_tls()).await.unwrap();
	let wire = tokio::task::spawn_local(wire);
	let schema = format!(
		"rooms_proof_{}_{}",
		std::process::id(),
		std::time::SystemTime::now()
			.duration_since(std::time::UNIX_EPOCH)
			.unwrap()
			.as_nanos()
	);
	database
		.batch_execute(&format!("CREATE SCHEMA {schema}; SET search_path TO {schema}"))
		.await
		.unwrap();
	let separator = if url.contains('?') { '&' } else { '?' };
	let storage = format!("{url}{separator}options=-csearch_path%3D{schema}");
	// Fixture uses the pre-migration schema and row names directly.
	database
		.batch_execute(
			"CREATE TABLE room_lines (
	 seq bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
	 room text NOT NULL, from_nick text NOT NULL, said text NOT NULL, at_ms bigint NOT NULL);
	 INSERT INTO room_lines(room,from_nick,said,at_ms) VALUES ('#garden','Bob','from the previous server',42)",
		)
		.await
		.unwrap();
	let mut server = Process::start(&storage);
	let location = server.ready();
	let mut rival = Process::start(&storage);
	assert!(rival.finish(false).contains("already held by another server"));
	let (runtime, client, directory) = member(&location).await;
	let garden = join(&client, &directory, "Garden").await;
	let studio = join(&client, &directory, "Studio").await;
	let kept = garden.history().await.unwrap();
	assert_eq!(
		(kept[0].from.as_str(), kept[0].text.as_str()),
		("Bob", "from the previous server")
	);
	let edited = garden.say("original").await.unwrap().unwrap();
	edited.edit("edited and retained").await.unwrap();
	let removed = garden.say("withdraw this").await.unwrap().unwrap();
	removed.withdraw().await.unwrap();
	studio.say("another room").await.unwrap();
	runtime.close(PendingWork::Cancel).await.unwrap();
	server.stop(); // Shutdown must drain every accepted history write.
	let rows = database
		.query("SELECT room,said FROM room_lines ORDER BY seq", &[])
		.await
		.unwrap();
	let rows: Vec<(String, String)> = rows.iter().map(|r| (r.get(0), r.get(1))).collect();
	assert_eq!(
		rows,
		[
			("#garden".into(), "from the previous server".into()),
			("#garden".into(), "edited and retained".into()),
			("#studio".into(), "another room".into())
		]
	);
	let mut restarted = Process::start(&storage);
	let (runtime, client, directory) = member(&restarted.ready()).await;
	let garden = join(&client, &directory, "Garden").await;
	assert_eq!(
		garden
			.history()
			.await
			.unwrap()
			.iter()
			.map(|line| line.text.as_str())
			.collect::<Vec<_>>(),
		["from the previous server", "edited and retained"]
	);
	let studio = join(&client, &directory, "Studio").await;
	assert_eq!(studio.history().await.unwrap()[0].text, "another room");
	database
		.batch_execute("ALTER TABLE room_lines ADD CONSTRAINT refuse_proof_line CHECK (said <> 'refused persistence')")
		.await
		.unwrap();
	// The post reply may race shutdown: persistence happens after admission.
	let _ = garden.say("refused persistence").await;
	assert!(restarted.finish(false).contains("23514"));
	runtime.close(PendingWork::Cancel).await.unwrap();
	let count: i64 = database
		.query_one("SELECT count(*) FROM room_lines", &[])
		.await
		.unwrap()
		.get(0);
	assert_eq!(count, 3, "a refused transaction is neither partially kept nor replayed");
	database
		.batch_execute("ALTER TABLE room_lines DROP CONSTRAINT refuse_proof_line")
		.await
		.unwrap();
	pressure(&database, &storage).await;
	// A bounded restore refuses oversized state before printing readiness.
	database
		.execute(
			"INSERT INTO room_lines(room,from_nick,said,at_ms) VALUES ('#garden','Bob',$1,43)",
			&[&"x".repeat(rooms_application::room::line::MAX_LINE_BYTES + 1)],
		)
		.await
		.unwrap();
	let mut invalid = Process::start(&storage);
	assert!(invalid.finish(false).contains("PostgreSQL history"));
	assert!(BufReader::new(invalid.0.stdout.take().unwrap())
		.lines()
		.next()
		.is_none());
	database
		.batch_execute(&format!("DROP SCHEMA {schema} CASCADE"))
		.await
		.unwrap();
	drop(database);
	wire.await.unwrap().unwrap();
}

fn database_tls() -> tokio_postgres_rustls::MakeRustlsConnect {
	use tokio_rustls::rustls::{
		self,
		pki_types::{pem::PemObject, CertificateDer},
	};
	let mut roots = rustls::RootCertStore::empty();
	roots
		.add(
			CertificateDer::from_pem_slice(include_bytes!(concat!(
				env!("CARGO_MANIFEST_DIR"),
				"/../../../../test/net/fixtures/tls_root.pem"
			)))
			.unwrap(),
		)
		.unwrap();
	let config =
		rustls::ClientConfig::builder_with_provider(std::sync::Arc::new(rustls::crypto::ring::default_provider()))
			.with_safe_default_protocol_versions()
			.unwrap()
			.with_root_certificates(roots)
			.with_no_client_auth();
	tokio_postgres_rustls::MakeRustlsConnect::new(config)
}

#[test]
#[ignore = "requires a TLS-enabled disposable PostgreSQL database with password authentication"]
fn postgres_refuses_wrong_password_and_hostname_without_readiness_or_secret_diagnostics() {
	let original = std::env::var("GLOWCAP_ROOMS_STORAGE_LIVE_URL").unwrap();
	let mut untrusted = Process::start_with_trust(&original, Some("/dev/null"));
	assert!(untrusted.finish(false).contains("TLS trust"));
	assert!(BufReader::new(untrusted.0.stdout.take().unwrap())
		.lines()
		.next()
		.is_none());
	let mut url = url::Url::parse(&original).unwrap();
	assert_eq!(
		url.host_str(),
		Some("localhost"),
		"the fixture certificate names localhost"
	);
	assert!(url
		.query_pairs()
		.any(|(key, value)| key == "sslmode" && value == "require"));
	url.set_password(Some("synthetic-wrong-password")).unwrap();
	let mut refused = Process::start(url.as_str());
	let diagnostic = refused.finish(false);
	assert!(
		diagnostic.contains("28P01"),
		"authentication refusal must retain SQLSTATE"
	);
	assert!(!diagnostic.contains("synthetic-wrong-password"));
	assert!(BufReader::new(refused.0.stdout.take().unwrap())
		.lines()
		.next()
		.is_none());
	let mut url = url::Url::parse(&original).unwrap();
	url.set_host(Some("127.0.0.1")).unwrap();
	let mut refused = Process::start(url.as_str());
	let diagnostic = refused.finish(false);
	assert!(diagnostic.contains("PostgreSQL history"));
	assert!(!diagnostic.contains(url.password().unwrap()));
	assert!(BufReader::new(refused.0.stdout.take().unwrap())
		.lines()
		.next()
		.is_none());
}

async fn pressure(database: &tokio_postgres::Client, storage: &str) {
	let mut server = Process::start(storage);
	let (runtime, client, directory) = member(&server.ready()).await;
	let garden = join(&client, &directory, "Garden").await;
	let studio = join(&client, &directory, "Studio").await;
	let mut file = garden
		.stage(rooms_application::files::FileDescription::parse("pressure.bin", "", 1, 0, 0).unwrap())
		.await
		.unwrap();
	database
		.batch_execute("BEGIN; LOCK room_lines IN ACCESS EXCLUSIVE MODE")
		.await
		.unwrap();
	let mut last = None;
	let mut refused = false;
	for n in 0..2048 {
		match garden.say(&format!("queued {n}")).await {
			Ok(line) => last = line,
			Err(error) => {
				assert!(error.to_string().contains("server is busy"));
				refused = true;
				break;
			}
		}
	}
	assert!(refused, "a blocked backend must bound admission");
	let before = garden.history().await.unwrap();
	let last = last.expect("at least one admitted line");
	assert!(last
		.edit("refused edit")
		.await
		.unwrap_err()
		.to_string()
		.contains("server is busy"));
	assert!(last
		.withdraw()
		.await
		.unwrap_err()
		.to_string()
		.contains("server is busy"));
	assert!(last
		.refile("refused refile", &[])
		.await
		.unwrap_err()
		.to_string()
		.contains("server is busy"));
	assert!(garden
		.post_files("refused files")
		.await
		.err()
		.unwrap()
		.to_string()
		.contains("server is busy"));
	assert!(studio
		.say("refused sibling")
		.await
		.err()
		.unwrap()
		.to_string()
		.contains("server is busy"));
	assert_eq!(
		garden.history().await.unwrap(),
		before,
		"refused mutations cannot alter the live tail"
	);
	database.batch_execute("COMMIT").await.unwrap();
	// Synchronize on actual database progress, not a guessed delay.
	let end = tokio::time::Instant::now() + Duration::from_secs(10);
	loop {
		let row: String = database
			.query_one(
				"SELECT said FROM room_lines WHERE room='#garden' ORDER BY seq DESC LIMIT 1",
				&[],
			)
			.await
			.unwrap()
			.get(0);
		if row == before.last().unwrap().text {
			break;
		}
		assert!(tokio::time::Instant::now() < end, "history drain deadline");
		tokio::task::yield_now().await;
	}
	// Failed refile/postFiles must leave the staged file available to retry.
	assert!(garden.post_files("retained files").await.unwrap().is_some());
	file.write(vec![7]).await.unwrap();
	assert!(file.complete());
	last.edit("retained edit").await.unwrap();
	last.withdraw().await.unwrap();
	studio.say("retained sibling").await.unwrap();
	let expected = garden.history().await.unwrap();
	runtime.close(PendingWork::Cancel).await.unwrap();
	server.stop();
	let rows: Vec<String> = database
		.query("SELECT said FROM room_lines WHERE room='#garden' ORDER BY seq", &[])
		.await
		.unwrap()
		.iter()
		.map(|row| row.get(0))
		.collect();
	assert_eq!(rows.len(), rooms_application::server::history::LINES_KEPT - 1);
	assert_eq!(
		&rows[rows.len() - expected.len()..],
		expected.iter().map(|line| line.text.clone()).collect::<Vec<_>>()
	);
	assert_eq!(rows.last().map(String::as_str), Some("retained files"));
	assert!(!rows.iter().any(|text| text.starts_with("refused")));
	let mut restarted = Process::start(storage);
	let (runtime, client, directory) = member(&restarted.ready()).await;
	let room = join(&client, &directory, "Garden").await;
	assert_eq!(room.history().await.unwrap(), expected);
	runtime.close(PendingWork::Cancel).await.unwrap();
	restarted.stop();
}
