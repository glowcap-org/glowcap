//! Human choices select typed custody and original command results. Routes are
//! transient acquisition input. Managed workspace rows contain no bearer links.
use super::{Failure, Options, acquisition::submit as acquire, command, request};
use rooms_application::{
	content::session::workspace,
	fields::{List, Text},
};
use serde_json::{Value, json};
use std::time::Duration;
fn rows<'a>(value: &'a Value, name: &str) -> Result<&'a Vec<Value>, Failure> {
	value[name]
		.as_array()
		.ok_or_else(|| Failure::invalid(format!("session response lacks {name}")))
}
fn rows_mut<'a>(value: &'a mut Value, name: &str) -> Result<&'a mut Vec<Value>, Failure> {
	value[name]
		.as_array_mut()
		.ok_or_else(|| Failure::invalid(format!("session response lacks {name}")))
}
fn id_text(row: &Value) -> Result<String, Failure> {
	row["id"]
		.as_str()
		.map(str::to_owned)
		.ok_or_else(|| Failure::invalid("session response row lacks id text"))
}
fn revision(status: &Value) -> Result<u64, Failure> {
	status["revision"]
		.as_str()
		.and_then(|v| v.parse().ok())
		.ok_or_else(|| Failure::invalid("session returned no workspace revision"))
}
fn coordinate(role: &str, key: &Value) -> Value {
	json!({"role":role,"key":key})
}
fn fresh() -> Result<Value, Failure> {
	Ok(json!(super::operation()?))
}
fn field<T: serde::de::DeserializeOwned>(value: Value) -> Result<T, Failure> {
	serde_json::from_value(value).map_err(|error| Failure::invalid(format!("invalid workspace field: {error}")))
}
fn setup(options: &Options) -> Options {
	let mut setup = options.clone();
	setup.named.remove("operation");
	setup.named.remove("base");
	setup
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
				format!("waiting for {description}; inspect the managed workspace and control log"),
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
		let address = request(&options.state, json!({"verb":"locate","locator":locator})).await?;
		if let Some(entry) = directories.iter().find(|row| row["id"] == address["id"]) {
			entry.clone()
		} else {
			let nick = options
				.get("nick")
				.ok_or_else(|| Failure::invalid("a new directory needs --nick"))?;
			let access = fresh()?;
			let source = fresh()?;
			let entry = json!({"id":address["id"],"access":access,"source":source,"home":directories.is_empty(),"nick":nick,"nickAllocation":"automatic","standing":null});
			let mut intent = status["workspace"].clone();
			rows_mut(&mut intent, "directories")?.push(entry.clone());
			acquire(options,json!({"kind":"workspace","base":revision(&status)?,"imports":[{"coordinate":coordinate("directoryAccess",&access),"uri":address["uri"]}],"source":source,"releases":[],"intent":intent})).await?;
			entry
		}
	} else {
		directories
			.iter()
			.find(|row| row["home"] == true)
			.cloned()
			.ok_or_else(|| Failure::invalid("name a directory with --locator and --nick"))?
	};
	if let Some(nick) = options.get("nick")
		&& entry["nick"] != nick
	{
		return Err(Failure::invalid(format!(
			"directory already requests nickname {}",
			entry["nick"]
		)));
	}
	let ready = wait(options, "directory registration", |s| {
		s["workspace"]["directories"].as_array().is_some_and(|rows| {
			rows.iter()
				.any(|row| row["id"] == entry["id"] && row["name"].is_string() && row["inbox"].is_string())
		})
	})
	.await?;
	rows(&ready["workspace"], "directories")?
		.iter()
		.find(|row| row["id"] == entry["id"])
		.cloned()
		.ok_or_else(|| Failure::invalid("registered directory left the workspace"))
}
struct ResultAcquisition {
	intent: Value,
	mappings: Vec<Value>,
	source: Value,
}
async fn acquire_result(
	options: &Options,
	submitted: &Value,
	name: &str,
	args: &[String],
	status: &Value,
	candidate: ResultAcquisition,
) -> Result<(), Failure> {
	let ResultAcquisition {
		intent,
		mappings,
		source,
	} = candidate;
	acquire(options,json!({"kind":"result","operation":submitted["operation"],"command_base":submitted["base"],"name":name,"args":args,"base":revision(status)?,"mappings":mappings,"releases":[],"intent":intent,"source":source})).await
}
pub async fn join(options: &Options) -> Result<Value, Failure> {
	let directory = directory(options).await?;
	let setup = setup(options);
	let mut joined = Vec::new();
	for name in options.values("room") {
		let status = request(&options.state, json!({"verb":"status"})).await?;
		let existing = rows(&status["workspace"], "conversations")?
			.iter()
			.find(|row| row["kind"] == "room" && row["directory"] == directory["id"] && row["name"] == name);
		let conversation = if let Some(existing) = existing {
			existing.clone()
		} else {
			let discovery = request(
				&options.state,
				json!({"verb":"directory-read","id":directory["id"],"peer":null,"name":name}),
			)
			.await?;
			let listed = rows(&discovery, "rooms")?
				.iter()
				.filter(|room| room["name"] == name)
				.collect::<Vec<_>>();
			if listed.len() > 1 {
				return Err(Failure::invalid("room name is ambiguous; use an exact room access"));
			}
			if let Some(room) = listed.first() {
				let id = super::operation()?;
				acquire(
					options,
					json!({"kind":"public-room", "base":revision(&status)?, "selection":{
						"id":id,"directory":directory["id"],"name":name,"publication":room["id"],"source":fresh()?
					}}),
				)
				.await?;
				json!({"id":id})
			} else {
				let (verb, args) = (
					"openManagedRoom",
					vec![
						id_text(&directory)?,
						name.clone(),
						"listed".into(),
						"open".into(),
						"open".into(),
						format!("~{}", super::operation()?),
					],
				);
				let submitted = command(&setup, verb, args.clone()).await?;
				let status = request(&options.state, json!({"verb":"status"})).await?;
				let source = fresh()?;
				let access = fresh()?;
				let control = fresh()?;
				let conversation = json!(workspace::Room {
					kind: workspace::RoomKind::Room,
					id: field(submitted["operation"].clone())?,
					directory: field(directory["id"].clone())?,
					name: field(json!(name))?,
					source: Some(field(source.clone())?),
					inbox: None,
					access: Some(field(access.clone())?),
					accepted: None,
					public_entry: None,
					publication: None,
					seat: None,
					topic: None,
					files: None,
					lines: List::default(),
					moderator: None,
					control: Some(field(control.clone())?),
					reconnect: workspace::Reconnect::Requested,
					standing: None,
					draft: Text::default(),
				});
				let mut intent = status["workspace"].clone();
				rows_mut(&mut intent, "conversations")?.push(conversation.clone());
				let result = &submitted["result"];
				let mappings = vec![
					json!([
						coordinate("roomAccess", &result["room"]),
						coordinate("roomAccess", &access)
					]),
					json!([
						coordinate("roomControl", &result["control"]),
						coordinate("roomControl", &control)
					]),
				];
				acquire_result(
					options,
					&submitted,
					verb,
					&args,
					&status,
					ResultAcquisition {
						intent,
						mappings,
						source,
					},
				)
				.await?;
				conversation
			}
		};
		wait(options, &format!("room {name} membership"), |s| {
			s["workspace"]["conversations"].as_array().is_some_and(|rows| {
				rows.iter()
					.any(|row| row["id"] == conversation["id"] && row["seat"].is_string())
			})
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
		let id = id
			.parse::<u64>()
			.map_err(|_| Failure::invalid("event id must be an integer"))?;
		let pending = request(
			&options.state,
			json!({"verb":"tick","wait":0,"after_id":id.saturating_sub(1)}),
		)
		.await?;
		let event = rows(&pending, "pending")?
			.iter()
			.find(|row| row["id"] == id)
			.ok_or_else(|| Failure::invalid("event id is not pending; run tick"))?;
		let target = &event["event"]["target"];
		if !matches!(target["kind"].as_str(), Some("room" | "direct")) {
			return Err(Failure::invalid("event is not a conversation message"));
		}
		return target["id"]
			.as_str()
			.map(str::to_owned)
			.ok_or_else(|| Failure::invalid("event lacks conversation"));
	}
	if let Some(id) = options.get("conversation") {
		if !conversations.iter().any(|row| row["id"] == id) {
			return Err(Failure::invalid("unknown conversation id"));
		}
		return Ok(id.into());
	}
	if let Some(name) = options.get("room") {
		let found = conversations
			.iter()
			.filter(|row| row["kind"] == "room" && row["name"] == name)
			.collect::<Vec<_>>();
		if found.len() != 1 {
			return Err(Failure::invalid("room is missing or ambiguous; use --conversation"));
		}
		return id_text(found[0]);
	}
	let peer = options
		.get("dm")
		.ok_or_else(|| Failure::invalid("choose a conversation"))?;
	let directory = directory(options).await?;
	let reader = request(
		&options.state,
		json!({"verb":"directory-read","id":directory["id"],"peer":peer}),
	)
	.await?;
	let registration = reader["registration"]
		.as_str()
		.ok_or_else(|| Failure::invalid("peer has no live registration"))?;
	let opening = super::operation()?;
	let introduction = json!(workspace::Introduction {
		access: field(directory["access"].clone())?,
		name: field(directory["name"].clone())?,
		callback: field(directory["inbox"].clone())?,
		registration: field(json!(registration))?,
		opening: field(json!(opening))?,
	});
	let status = request(&options.state, json!({"verb":"status"})).await?;
	check_contact(&status, &directory)?;
	if let Some(row) = rows(&status["workspace"], "conversations")?.iter().find(|row| {
		row["kind"] == "direct"
			&& row["directory"] == directory["id"]
			&& row["peer"] == peer
			&& row["closed"] == false
			&& ["access", "name", "callback", "registration"]
				.iter()
				.all(|key| row["introduction"][key] == introduction[key])
	}) {
		return id_text(row);
	}
	let args = vec![id_text(&directory)?, peer.into(), registration.into(), opening.clone()];
	let setup = setup(options);
	let mut submitted = super::admission::command_at(&setup, "startDirect", args.clone(), status.clone()).await?;
	if submitted["result"]["status"] == "pending" {
		let deadline = tokio::time::Instant::now() + Duration::from_secs(25);
		let mut after_id = 0;
		let mut after = None::<u64>;
		loop {
			let batch = request(
				&options.state,
				json!({"verb":"tick","wait":1,"after_id":after_id,"after":after}),
			)
			.await?;
			if rows(&batch, "pending")?.iter().any(|row| {
				row["event"]["target"]["id"] == directory["id"]
					&& row["event"]["notice"]["kind"] == "introducible"
					&& row["event"]["notice"]["registration"] == registration
					&& row["event"]["notice"]["opening"] == opening
			}) {
				break;
			}
			after = batch["cursor"].as_u64();
			if let Some(row) = rows(&batch, "pending")?.last() {
				after_id = row["id"]
					.as_u64()
					.ok_or_else(|| Failure::invalid("inbox event lacks id"))?;
			}
			if tokio::time::Instant::now() >= deadline {
				return Err(Failure::uncertain("peer introduction remains pending"));
			}
		}
		submitted = super::admission::command_at(&setup, "startDirect", args.clone(), status).await?;
	}
	if submitted["result"]["status"] != "ready" {
		return Err(Failure::uncertain("peer has not supplied a direct inbox"));
	}
	let status = request(&options.state, json!({"verb":"status"})).await?;
	check_contact(&status, &directory)?;
	let id = super::operation()?;
	let source = fresh()?;
	let access = fresh()?;
	let mut intent = status["workspace"].clone();
	rows_mut(&mut intent, "conversations")?.push(json!({"kind":"direct","id":id,"directory":directory["id"],"peer":peer,"source":source,"access":access,"introduction":introduction,"closed":false,"draft":""}));
	acquire_result(
		options,
		&submitted,
		"startDirect",
		&args,
		&status,
		ResultAcquisition {
			intent,
			mappings: vec![json!([
				coordinate("directAccess", &submitted["result"]["inbox"]),
				coordinate("directAccess", &access)
			])],
			source,
		},
	)
	.await?;
	wait(options, "direct inbox", |s| {
		s["workspace"]["conversations"]
			.as_array()
			.is_some_and(|rows| rows.iter().any(|row| row["id"] == id && row["inbox"].is_string()))
	})
	.await?;
	Ok(id)
}
fn check_contact(status: &Value, original: &Value) -> Result<(), Failure> {
	let current = rows(&status["workspace"], "directories")?
		.iter()
		.find(|row| row["id"] == original["id"])
		.ok_or_else(|| Failure::invalid("the initiating directory was removed; retain its receipt"))?;
	if !super::admission::same_directory_contact(original, current) {
		return Err(Failure::invalid(
			"the initiating registration changed; retain its receipt",
		));
	}
	Ok(())
}

#[cfg(test)]
mod tests;
