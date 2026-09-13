//! How the server reads its options: arguments over environment, the state
//! directory, transports and their refusals, history and where it is kept,
//! and a database password that arrives in a file rather than a URL.
use super::*;

#[test]
fn rooms_server_configuration_resolves_options_and_environment() {
	let parse = |args: &[&str]| Config::parse(args.iter().map(|s| s.to_string()), |_| None);
	// Without a state directory the server is process-local.
	assert!(parse(&[]).unwrap().unwrap().state.is_none());
	assert!(parse(&["--help"]).unwrap().is_none());
	assert!(matches!(
		parse(&["--state=place"]).unwrap().unwrap().transport,
		Transport::Iroh(iroh::Reachability::Discovery)
	));
	for args in [
		vec!["--state=place", "--transport=no"],
		vec!["--state=place", "--state=again"],
		vec!["--state=place", "--wrong=x"],
		vec!["--state=place", "--transport=tcp", "--bind=0.0.0.0"],
		vec!["--state=place", "--transport=tcp", "--port=65536"],
	] {
		assert!(parse(&args).is_err(), "{args:?}");
	}
	let config = Config::parse(["--port=7".into()], |key| match key {
		"GLOWCAP_ROOMS_STATE" => Some(" place ".into()),
		"GLOWCAP_ROOMS_TRANSPORT" => Some("tcp".into()),
		"GLOWCAP_ROOMS_PORT" => Some("8".into()),
		_ => None,
	})
	.unwrap()
	.unwrap();
	assert_eq!(config.state, Some(PathBuf::from("place")));
	assert!(!config.history);
	let kept = Config::parse(["--history".into(), "--storage=kept".into()], |_| None)
		.unwrap()
		.unwrap();
	assert!(kept.history);
	assert!(
		matches!(kept.history_storage(), Some(Storage::Files(path)) if path == std::path::Path::new("kept/history"))
	);
	assert!(Config::parse(["--storage=postgres://x".into()], |_| None).is_err());
	let database = Config::parse(["--storage=postgres://alice:secret@localhost/rooms".into()], |_| None)
		.unwrap()
		.unwrap();
	assert!(database.history);
	assert!(matches!(database.history_storage(), Some(Storage::Postgres(_))));
	assert!(!format!("{:?}", database.storage).contains("secret"));
	let refused = Storage::parse("postgres://alice:secret@localhost:invalid/rooms")
		.unwrap_err()
		.to_string();
	assert!(!refused.contains("secret"));
	assert!(Config::parse(["--state".into()], |_| None).is_err());
	let ephemeral = Config::parse(["--history".into()], |_| None).unwrap().unwrap();
	assert!(ephemeral.history_storage().is_none(), "history in memory alone");
	assert!(matches!(config.transport, Transport::Tcp { port: 7, .. }));
}

// The password may come from a file the orchestrator mounts, and then the
// URL must not carry one too: two authorities for one secret is refused, as
// is a file with nothing in it, a file beside a file destination, or a file
// that cannot be read. No refusal repeats a secret it saw.
#[test]
fn rooms_server_configuration_takes_the_database_password_from_a_file() {
	struct Temp(PathBuf);
	impl Drop for Temp {
		fn drop(&mut self) {
			let _ = std::fs::remove_dir_all(&self.0); // best-effort: a leftover temp dir is the only loss
		}
	}
	let secret_dir = Temp(std::env::temp_dir().join(format!("rooms-storage-password-{}", std::process::id())));
	std::fs::create_dir_all(&secret_dir.0).unwrap();
	let secret_file = secret_dir.0.join("password");
	std::fs::write(&secret_file, "hunter2\n").unwrap();
	let filed = Config::parse(
		[
			"--storage=postgres://alice@localhost/rooms".into(),
			format!("--storage-password-file={}", secret_file.display()),
		],
		|_| None,
	)
	.unwrap()
	.unwrap();
	assert!(matches!(
		filed.storage,
		Some(Storage::Postgres(ref config)) if config.0.get_password() == Some(b"hunter2".as_slice())
	));
	let from_env = Config::parse([], |key| match key {
		"GLOWCAP_ROOMS_STORAGE" => Some("postgres://alice@localhost/rooms".into()),
		"GLOWCAP_ROOMS_STORAGE_PASSWORD_FILE" => Some(secret_file.display().to_string()),
		_ => None,
	})
	.unwrap()
	.unwrap();
	assert!(matches!(
		from_env.storage,
		Some(Storage::Postgres(ref config)) if config.0.get_password() == Some(b"hunter2".as_slice())
	));
	for args in [
		vec![
			"--storage=postgres://alice:secret@localhost/rooms".to_string(),
			format!("--storage-password-file={}", secret_file.display()),
		],
		vec![format!("--storage-password-file={}", secret_file.display())],
		vec![
			"--storage=kept".to_string(),
			format!("--storage-password-file={}", secret_file.display()),
		],
		vec![
			"--storage=postgres://alice@localhost/rooms".to_string(),
			format!("--storage-password-file={}", secret_dir.0.join("absent").display()),
		],
	] {
		let refused = match Config::parse(args.clone(), |_| None) {
			Err(error) => error.to_string(),
			Ok(_) => panic!("{args:?} was accepted"),
		};
		assert!(
			!refused.contains("secret") && !refused.contains("hunter2"),
			"{args:?}: {refused}"
		);
	}
	std::fs::write(&secret_file, "\n").unwrap();
	assert!(
		Config::parse(
			[
				"--storage=postgres://alice@localhost/rooms".into(),
				format!("--storage-password-file={}", secret_file.display()),
			],
			|_| None,
		)
		.is_err()
	);
}
