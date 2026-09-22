//! Resolve human choices into shared application commands; no wire behavior.
use super::{Failure, Options, command, request};
use serde_json::{Value, json};
use std::time::Duration;
fn rows<'a>(value: &'a Value, name: &str) -> Result<&'a Vec<Value>, Failure> {
	value[name]
		.as_array()
		.ok_or_else(|| Failure::invalid(format!("session response lacks {name}")))
}
pub async fn wait(options: &Options, description: &str, predicate: impl Fn(&Value) -> bool) -> Result<Value, Failure> {
	let deadline = tokio::time::Instant::now() + Duration::from_secs(25);
	loop {
		let status = request(&options.state, json!({"verb":"status"})).await?;
		if predicate(&status) {
			return Ok(status);
		}
		if tokio::time::Instant::now() >= deadline {
			return Err(Failure::new(
				"timeout",
				"after-state-change",
				format!(
					"waiting for {description}; session remains available; issues: {}",
					status["issues"]
				),
			));
		}
		tokio::time::sleep(Duration::from_millis(100)).await;
	}
}
pub async fn directory(options: &Options) -> Result<Value, Failure> {
	let status = request(&options.state, json!({"verb":"status"})).await?;
	let directories = rows(&status["workspace"], "directories")?;
	let entry = if let Some(locator) = options.get("locator") {
		let locator = super::bootstrap::resolve(locator).await?;
		let address = request(&options.state, json!({"verb":"locate", "locator":locator})).await?;
		if let Some(entry) = directories.iter().find(|d| d["id"] == address["id"]) {
			entry.clone()
		} else {
			let nick = options
				.get("nick")
				.ok_or_else(|| Failure::invalid("a new directory needs --nick"))?;
			let entry = json!({"id":address["id"], "locator":address["locator"], "nick":nick, "home":directories.is_empty(), "standing":null});
			command(options, "joinDirectory", vec![entry.to_string()]).await?;
			entry
		}
	} else {
		directories
			.iter()
			.find(|d| d["home"] == true)
			.cloned()
			.ok_or_else(|| Failure::invalid("name a directory with --locator and --nick"))?
	};
	if let Some(nick) = options.get("nick")
		&& entry["nick"] != nick
	{
		return Err(Failure::invalid(format!(
			"directory already uses nickname {}",
			entry["nick"]
		)));
	}
	wait(options, "directory connection", |s| {
		s["connected"]
			.as_array()
			.is_some_and(|rows| rows.contains(&entry["id"]))
	})
	.await?;
	Ok(entry)
}
pub async fn join(options: &Options) -> Result<Value, Failure> {
	let directory = directory(options).await?;
	let mut joined = Vec::new();
	for name in options.values("room") {
		let status = request(&options.state, json!({"verb":"status"})).await?;
		let conversations = rows(&status["workspace"], "conversations")?;
		let existing = conversations
			.iter()
			.find(|c| c["kind"] == "room" && c["directory"] == directory["id"] && c["name"] == name);
		let conversation = if let Some(c) = existing {
			c.clone()
		} else {
			let conversation = json!({"kind":"room", "id":super::operation()?, "directory":directory["id"], "name":name, "held":false, "standing":null, "draft":""});
			command(
				options,
				"joinRoom",
				vec![
					json!({"locator":directory["locator"],"nick":directory["nick"],"conversation":conversation})
						.to_string(),
				],
			)
			.await?;
			conversation
		};
		wait(options, &format!("room {name}"), |s| {
			s["rooms"]
				.as_array()
				.is_some_and(|rows| rows.iter().any(|r| r["conversationId"] == conversation["id"]))
		})
		.await?;
		joined.push(json!({"room":name,"conversation":conversation["id"]}));
	}
	Ok(json!({"ok":true,"joined":joined}))
}
pub async fn target(options: &Options) -> Result<String, Failure> {
	let status = request(&options.state, json!({"verb":"status"})).await?;
	let conversations = rows(&status["workspace"], "conversations")?;
	if let Some(id) = options.get("id") {
		let pending = request(&options.state, json!({"verb":"tick","wait":0})).await?;
		let event = rows(&pending, "pending")?
			.iter()
			.find(|r| r["id"] == id.parse::<u64>().unwrap())
			.ok_or_else(|| Failure::invalid("event id is not in the pending batch; run tick"))?;
		return Ok(event["conversation"]
			.as_str()
			.ok_or_else(|| Failure::invalid("event lacks conversation"))?
			.into());
	}
	if let Some(id) = options.get("conversation") {
		if !conversations.iter().any(|c| c["id"] == id) {
			return Err(Failure::invalid("unknown conversation id"));
		}
		return Ok(id.into());
	}
	if let Some(name) = options.get("room") {
		let matches: Vec<_> = conversations
			.iter()
			.filter(|c| c["kind"] == "room" && c["name"] == name)
			.collect();
		if matches.len() != 1 {
			return Err(Failure::invalid("room is missing or ambiguous; use --conversation"));
		}
		return Ok(matches[0]["id"].as_str().unwrap().into());
	}
	let name = options
		.get("dm")
		.ok_or_else(|| Failure::invalid("choose a conversation"))?;
	let directory = directory(options).await?;
	let status = request(&options.state, json!({"verb":"status"})).await?;
	let view = rows(&status, "directories")?
		.iter()
		.find(|d| d["directoryId"] == directory["id"])
		.ok_or_else(|| Failure::invalid("directory is not connected"))?;
	let peer = rows(view, "peers")?
		.iter()
		.find(|p| p["name"] == name)
		.ok_or_else(|| Failure::invalid("peer is not registered; inspect status"))?;
	let existing = conversations.iter().find(|c| {
		c["kind"] == "direct" && c["directory"] == directory["id"] && c["peerRegistrationId"] == peer["registrationId"]
	});
	let conversation = match existing {
		Some(c) => c.clone(),
		None => {
			json!({"kind":"direct", "id":super::operation()?, "directory":directory["id"], "peer":name, "peerRegistrationId":peer["registrationId"],"closed":false,"draft":""})
		}
	};
	// A caller's operation id identifies its send, not this prerequisite.
	let mut setup = options.clone();
	setup.named.remove("operation");
	command(&setup, "startDirect", vec![conversation.to_string()]).await?;
	Ok(conversation["id"].as_str().unwrap().into())
}
