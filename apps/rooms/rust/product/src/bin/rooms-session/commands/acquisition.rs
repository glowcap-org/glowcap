//! Persist the exact acquisition recipe before sending it. Socket interruption
//! lends a wait to the adapter's receiver. Restart replays this same candidate.
//! This private file stores request material, never a replacement grant ledger.
use super::{Failure, Options, request, request_encoded};
use serde::Deserialize;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const MAX_BYTES: usize = 1024 * 1024;
pub(super) fn validate_id(id: &str) -> Result<(), Failure> {
	if id.len() != 32
		|| !id
			.bytes()
			.all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
	{
		return Err(Failure::invalid(
			"acquisition identity must be 32 lowercase hexadecimal digits",
		));
	}
	Ok(())
}
fn path(state: &Path, id: &str) -> Result<PathBuf, Failure> {
	validate_id(id)?;
	Ok(state.join("recovery").join(format!("acquisition-{id}.json")))
}
async fn sync(directory: &Path) -> Result<(), Failure> {
	tokio::fs::File::open(directory).await?.sync_all().await?;
	Ok(())
}
pub async fn submit(options: &Options, body: Value) -> Result<(), Failure> {
	let id = super::operation()?;
	let envelope = json!({"verb":"acquire","id":id,"request":body});
	let encoded = serde_json::to_vec(&envelope)?;
	if encoded.len() + 1 > MAX_BYTES {
		return Err(Failure::exhausted("acquisition exceeds the 1 MiB socket profile"));
	}
	let target = path(&options.state, &id)?;
	let directory = target
		.parent()
		.ok_or_else(|| Failure::invalid("acquisition recovery path has no directory"))?;
	tokio::fs::create_dir_all(directory).await?;
	#[cfg(unix)]
	{
		use std::os::unix::fs::PermissionsExt;
		tokio::fs::set_permissions(directory, std::fs::Permissions::from_mode(0o700)).await?;
	}
	let mut opening = tokio::fs::OpenOptions::new();
	opening.write(true).create_new(true);
	#[cfg(unix)]
	opening.mode(0o600);
	let mut file = opening.open(&target).await?;
	file.write_all(&encoded).await?;
	file.sync_all().await?;
	sync(directory).await?;
	sync(&options.state).await?;
	finish(&options.state, &id, &encoded).await
}
async fn finish(state: &Path, id: &str, encoded: &[u8]) -> Result<(), Failure> {
	let outcome = async {
		request_encoded(state, "acquire", encoded).await?;
		request(state, json!({"verb":"release-acquisition","id":id})).await?;
		Ok(())
	}
	.await;
	outcome.map_err(|mut error: Failure| {
		error.message = format!(
			"acquisition {id}: {}; resume with rooms session recover --dir <workspace> --acquisition {id}",
			error.message
		);
		error
	})?;
	let target = path(state, id)?;
	let cleanup = async {
		tokio::fs::remove_file(&target).await?;
		sync(
			target
				.parent()
				.ok_or_else(|| Failure::invalid("acquisition recovery path has no directory"))?,
		)
		.await
	}
	.await;
	cleanup.map_err(|mut error: Failure| {
		error.message = format!(
			"acquisition {id} completed; recovery file cleanup failed: {}; inspect status before another acquisition",
			error.message
		);
		error
	})
}
pub async fn recover(options: &Options) -> Result<Value, Failure> {
	let id = options
		.get("acquisition")
		.ok_or_else(|| Failure::invalid("--acquisition is required"))?;
	let mut bytes = Vec::new();
	tokio::fs::File::open(path(&options.state, id)?)
		.await?
		.take(MAX_BYTES as u64 + 1)
		.read_to_end(&mut bytes)
		.await?;
	if bytes.len() > MAX_BYTES {
		return Err(Failure::invalid("saved acquisition exceeds its profile"));
	}
	#[derive(Deserialize)]
	#[serde(deny_unknown_fields)]
	struct Envelope<'a> {
		verb: &'a str,
		id: &'a str,
		#[serde(borrow)]
		request: &'a serde_json::value::RawValue,
	}
	let envelope: Envelope<'_> = serde_json::from_slice(&bytes)?;
	if envelope.verb != "acquire" || envelope.id != id || !envelope.request.get().starts_with('{') {
		return Err(Failure::invalid("saved acquisition has another identity"));
	}
	finish(&options.state, id, &bytes).await?;
	Ok(json!({"ok":true,"acquisition":id}))
}

#[cfg(test)]
mod tests {
	use super::*;
	use tokio::{
		io::{AsyncBufReadExt, BufReader},
		net::UnixListener,
	};

	#[tokio::test]
	async fn interruption_retains_exact_request_until_recovery_completes() {
		let state = std::env::temp_dir().join(format!("rooms-acquisition-{}", super::super::operation().unwrap()));
		tokio::fs::create_dir(&state).await.unwrap();
		let listener = UnixListener::bind(state.join("control.sock")).unwrap();
		let options = Options {
			verb: "recover".into(),
			state: state.clone(),
			named: Default::default(),
			arguments: Vec::new(),
		};
		let refusing = tokio::spawn(async move {
			let (stream, _) = listener.accept().await.unwrap();
			let mut line = String::new();
			BufReader::new(stream).read_line(&mut line).await.unwrap();
			(listener, line)
		});
		assert!(
			submit(
				&options,
				json!({"kind":"workspace", "base":17, "source":"original-source"})
			)
			.await
			.is_err()
		);
		let (listener, sent) = refusing.await.unwrap();
		let envelope: Value = serde_json::from_str(&sent).unwrap();
		let id = envelope["id"].as_str().unwrap();
		let saved = tokio::fs::read(path(&state, id).unwrap()).await.unwrap();
		assert_eq!(saved, sent.trim_end().as_bytes());
		let accepting = tokio::spawn(async move {
			let mut received = Vec::new();
			for _ in 0..2 {
				let (stream, _) = listener.accept().await.unwrap();
				let mut stream = BufReader::new(stream);
				let mut line = String::new();
				stream.read_line(&mut line).await.unwrap();
				stream.get_mut().write_all(b"{\"ok\":true}\n").await.unwrap();
				received.push(line);
			}
			received
		});
		let mut options = options;
		options.named.insert("acquisition".into(), vec![id.into()]);
		recover(&options).await.unwrap();
		let received = accepting.await.unwrap();
		assert_eq!(received[0], sent);
		assert_eq!(
			serde_json::from_str::<Value>(&received[1]).unwrap(),
			json!({"verb":"release-acquisition", "id":id})
		);
		assert!(!path(&state, id).unwrap().exists());
		tokio::fs::remove_dir_all(state).await.unwrap();
	}
}
