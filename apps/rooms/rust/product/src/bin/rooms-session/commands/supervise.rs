//! Supervise only the process this start creates. Workspace and lifecycle leases
//! make concurrent starts explicit; settings are durable before process launch.
use super::{Failure, Options, request, workspace};
use serde_json::{Value, json};
use std::os::unix::process::CommandExt;
use std::{collections::BTreeMap, path::Path, process::Stdio, time::Duration};
use tokio::process::Command;

pub async fn start(options: &Options) -> Result<Value, Failure> {
	// Resolve before creating state or launching a peer. Keep the original URL
	// in settings for relay derivation, but join with this resolved locator.
	let mut joining = options.clone();
	if let Some(locator) = options.get("locator") {
		joining
			.named
			.insert("locator".into(), vec![super::bootstrap::resolve(locator).await?]);
	}
	let state = options.state.clone();
	let lease = tokio::task::spawn_blocking(move || {
		rooms_platform::storage::Directory::open(state.join("lifecycle"), "lock").map_err(Failure::from)
	})
	.await
	.map_err(Failure::uncertain)??;
	let running = match tokio::net::UnixStream::connect(options.state.join("control.sock")).await {
		Ok(_) => true,
		Err(error)
			if matches!(
				error.kind(),
				std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused
			) =>
		{
			false
		}
		Err(error) => return Err(error.into()),
	};
	let state = options.state.clone();
	let supplied = options.clone();
	let settings = tokio::task::spawn_blocking(move || {
		use rooms_platform::storage::atomic;
		if state.join("state.json").exists() {
			return Err(Failure::invalid(
				"this directory holds a different workspace format; preserve it and choose a new --dir",
			));
		}
		let path = state.join("peer-options.json");
		let raw = rooms_platform::storage::read(&path, 16 * 1024)
			.map_err(|e| Failure::new("storage", "after-state-change", e))?;
		let mut settings: BTreeMap<String, String> = raw
			.map(|raw| serde_json::from_slice(&raw))
			.transpose()?
			.unwrap_or_default();
		settings.entry("transport".into()).or_insert("iroh".into());
		for key in ["transport", "reachability", "relay-url"] {
			if let Some(value) = supplied.get(key) {
				if running && settings.get(key).map(String::as_str) != Some(value) {
					return Err(Failure::invalid("stop the session before changing transport settings"));
				}
				settings.insert(key.into(), value.into());
			}
		}
		if !settings.contains_key("relay-url")
			&& let Some(locator) = supplied.get("locator")
			&& (locator.starts_with("http://") || locator.starts_with("https://"))
		{
			let mut url = url::Url::parse(locator).map_err(Failure::invalid)?;
			url.set_scheme(if url.scheme() == "https" { "wss" } else { "ws" })
				.map_err(|_| Failure::invalid("invalid bootstrap scheme"))?;
			url.set_path("/relay");
			url.set_query(None);
			url.set_fragment(None);
			settings.insert("relay-url".into(), url.into());
		}
		let mut arguments = vec![format!("--state={}", state.display())];
		arguments.extend(settings.iter().map(|(key, value)| format!("--{key}={value}")));
		rooms_services::session::Config::parse(arguments, |key| std::env::var(key).ok()).map_err(Failure::invalid)?;
		let bytes = serde_json::to_vec(&settings)?;
		if !running {
			atomic::replace_at(&state, "peer-options.json", [&bytes[..]])
				.map_err(|e| Failure::uncertain(format!("{e:?}")))?;
		}
		Ok::<_, Failure>(settings)
	})
	.await
	.map_err(Failure::uncertain)??;
	// A connect probe does not send a mutating request or reinterpret errors.
	match tokio::net::UnixStream::connect(options.state.join("control.sock")).await {
		Ok(_) => {
			request(&options.state, json!({"verb":"status"})).await?;
		}
		Err(error)
			if matches!(
				error.kind(),
				std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused
			) =>
		{
			let executable = std::env::current_exe()?;
			let log = std::fs::OpenOptions::new()
				.create(true)
				.append(true)
				.open(options.state.join("control.log"))?;
			let mut launch = Command::new(executable);
			launch
				.arg(format!("--state={}", options.state.display()))
				.arg("--local-control");
			for (key, value) in settings {
				launch.arg(format!("--{key}={value}"));
			}
			launch
				.stdin(Stdio::null())
				.stdout(log.try_clone()?)
				.stderr(log)
				.current_dir(&options.state);
			launch.as_std_mut().process_group(0);
			let mut child = launch.spawn()?;
			let started = async {
				let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
				loop {
					if let Some(status) = child.try_wait()? {
						return Err(Failure::new(
							"closed",
							"after-state-change",
							format!("session exited ({status}); inspect control.log"),
						));
					}
					if tokio::net::UnixStream::connect(options.state.join("control.sock"))
						.await
						.is_ok()
					{
						request(&options.state, json!({"verb":"status"})).await?;
						return Ok(());
					}
					if tokio::time::Instant::now() >= deadline {
						return Err(Failure::new(
							"timeout",
							"after-state-change",
							"startup timed out; inspect control.log",
						));
					}
					tokio::time::sleep(Duration::from_millis(50)).await;
				}
			}
			.await;
			if let Err(error) = started {
				if child.try_wait()?.is_none() {
					child
						.kill()
						.await
						.map_err(|cleanup| Failure::uncertain(format!("{error}; cleanup: {cleanup}")))?;
				}
				return Err(error);
			}
		}
		Err(error) => return Err(error.into()),
	}
	request(&options.state, json!({"verb":"adopt"})).await?;
	drop(lease);
	if !options.values("room").is_empty() {
		workspace::join(&joining).await
	} else {
		if options.get("locator").is_some() {
			workspace::directory(&joining).await?;
		}
		request(&options.state, json!({"verb":"status"})).await
	}
}

pub fn state_path(root: &Path, nick: &str) -> Result<std::path::PathBuf, Failure> {
	if nick.is_empty()
		|| nick.len() > rooms_application::room::inbox::MAX_NICK
		|| !nick
			.bytes()
			.all(|c| c.is_ascii_alphanumeric() || c == b'_' || c == b'-')
	{
		return Err(Failure::invalid(
			"roster nicknames use letters, digits, underscore, or hyphen",
		));
	}
	Ok(root.join(nick))
}
