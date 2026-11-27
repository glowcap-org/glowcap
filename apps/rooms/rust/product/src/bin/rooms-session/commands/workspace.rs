//! Human choices select typed custody and original command results. Routes are
//! transient acquisition input. Managed workspace rows contain no bearer links.
use super::{Failure, Options, acquisition::at_current, command, request};
use rooms_application::failure::Retry;
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
pub async fn wait(
	options: &Options,
	description: &str,
	mut predicate: impl AsyncFnMut(&Value) -> Result<bool, Failure>,
) -> Result<Value, Failure> {
	let deadline = tokio::time::Instant::now() + Duration::from_secs(25);
	loop {
		let status = request(&options.state, json!({"verb":"status"})).await?;
		if predicate(&status).await? {
			return Ok(status);
		}
		if tokio::time::Instant::now() >= deadline {
			return Err(Failure::new(
				"timeout",
				Retry::AfterStateChange,
				format!("waiting for {description}; inspect the managed workspace and control log"),
			));
		}
		tokio::time::sleep(Duration::from_millis(100)).await;
	}
}
pub async fn directory(options: &Options) -> Result<Value, Failure> {
	use rooms_application::directory::registration::NicknameAllocation;
	let exact = options.get("exact-nick") == Some("true");
	let allocation = if exact {
		NicknameAllocation::Exact
	} else {
		NicknameAllocation::Automatic
	};
	let mut resolved = None;
	let mut entry = Value::Null;
	at_current(options, async |status, base| {
		let directories = rows(&status["workspace"], "directories")?;
		// Re-evaluate the home after a conflicting write, before consulting even a
		// previously resolved fallback. Only an explicit locator selects another directory.
		let locator = options.get("locator").or_else(|| {
			options.get("home-locator").filter(|_| !directories.iter().any(|row| row["home"] == true))
		});
		let address = if let Some(locator) = locator {
			if resolved.is_none() {
				let locator = super::bootstrap::resolve(locator).await?;
				resolved = Some(request(&options.state, json!({"verb":"locate","locator":locator})).await?);
			}
			resolved.as_ref()
		} else {
			None
		};
		if let Some(index) = directories.iter().position(|row| match address {
			Some(address) => row["id"] == address["id"],
			None => row["home"] == true,
		}) {
			entry = directories[index].clone();
			if let Some(nick) = options.get("nick") && entry["nick"] != nick {
				return Err(Failure::invalid(format!(
					"this workspace's nickname is {} and stays with it. To use the nickname {nick:?}, start a new workspace with another --dir", entry["nick"]
				)));
			}
			if exact {
				check_assignment(&entry)?;
				if entry["nickAllocation"] != allocation.wire() {
					let mut intent = status["workspace"].clone();
					rows_mut(&mut intent, "directories")?[index]["nickAllocation"] = json!(allocation);
					return Ok(Some(json!({"kind":"workspace","base":base,"imports":[],"releases":[],"intent":intent})));
				}
			}
			return Ok(None);
		}
		let address = address.ok_or_else(|| Failure::invalid("name a directory with --locator and --nick"))?;
		let nick = options.get("nick").ok_or_else(|| Failure::invalid("a new directory needs --nick"))?;
		let access = fresh()?;
		let source = fresh()?;
		entry = json!({"id":address["id"],"access":access,"source":source,"home":directories.is_empty(),"nick":nick,"nickAllocation":allocation,"standing":null});
		let mut intent = status["workspace"].clone();
		rows_mut(&mut intent, "directories")?.push(entry.clone());
		Ok(Some(json!({"kind":"workspace","base":base,"imports":[{"coordinate":coordinate("directoryAccess",&access),"uri":address["uri"]}],"source":source,"releases":[],"intent":intent})))
	})
	.await?;
	let mut retry = entry["inbox"].clone();
	let ready = wait(options, "directory registration", async |status| {
		let Some(row) = rows(&status["workspace"], "directories")?
			.iter()
			.find(|row| row["id"] == entry["id"])
		else {
			return Err(Failure::invalid("the directory left the workspace during registration"));
		};
		if exact {
			check_assignment(row)?;
			if row["nick"] != entry["nick"] || row["nickAllocation"] != allocation.wire() {
				return Err(Failure::invalid(
					"the requested exact nickname changed during registration",
				));
			}
			let Some(inbox) = row["inbox"].as_str() else {
				return Ok(false);
			};
			// Only retry an inbox that stood at the beginning of this command.
			// A failure from the attempt this command started is its answer.
			let again = retry.take() == inbox;
			let live = request(
				&options.state,
				json!({"verb":"registration-ready","inbox":inbox,"retry":again}),
			)
			.await?;
			if live["ready"] != true {
				return Ok(false);
			}
		}
		Ok(row["name"].is_string() && row["inbox"].is_string())
	})
	.await?;
	rows(&ready["workspace"], "directories")?
		.iter()
		.find(|row| row["id"] == entry["id"])
		.cloned()
		.ok_or_else(|| Failure::invalid("registered directory left the workspace"))
}

fn check_assignment(row: &Value) -> Result<(), Failure> {
	if let Some(assigned) = row["assignedNick"].as_str()
		&& row["nick"] != assigned
	{
		return Err(Failure::invalid(format!(
			"this workspace registered as {assigned:?}. To require the exact nickname {}, choose an available name and start a new workspace",
			row["nick"]
		)));
	}
	Ok(())
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
				join_listed_room(options, &directory, room).await?
			} else if options.get("existing-room") == Some("true") {
				return Err(Failure::new(
					"no-such-room",
					Retry::AfterStateChange,
					format!(
						"no listed room named {name:?} was found. Check the spelling or create the room before joining"
					),
				));
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
					subject: None,
					files: None,
					lines: List::default(),
					moderator: None,
					control: Some(field(control.clone())?),
					reconnect: workspace::Reconnect::Requested,
					standing: None,
					draft: Text::default(),
				});
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
				at_current(options, async |status, base| {
					let mut intent = status["workspace"].clone();
					rows_mut(&mut intent, "conversations")?.push(conversation.clone());
					Ok(Some(json!({"kind":"result","operation":submitted["operation"],
						"command_base":submitted["base"],"name":verb,"args":args,"base":base,
						"mappings":mappings,"releases":[],"intent":intent,"source":source})))
				})
				.await?;
				conversation
			}
		};
		wait(options, &format!("room {name} membership"), async |s| {
			Ok(s["workspace"]["conversations"].as_array().is_some_and(|rows| {
				rows.iter()
					.any(|row| row["id"] == conversation["id"] && row["seat"].is_string())
			}))
		})
		.await?;
		joined.push(json!({"room":name,"conversation":conversation["id"]}));
	}
	Ok(json!({"ok":true,"joined":joined}))
}
/// A directory and publication identify the room. If another join installs it
/// before this acquisition, the revision retry adopts that conversation.
async fn join_listed_room(options: &Options, directory: &Value, listing: &Value) -> Result<Value, Failure> {
	let directory = id_text(directory)?;
	let publication = id_text(listing)?;
	let mut id = super::operation()?;
	let selection =
		json!({"id":id,"directory":directory,"name":listing["name"],"publication":publication,"source":fresh()?});
	at_current(options, async |status, base| {
		if let Some(joined) = rows(&status["workspace"], "conversations")?
			.iter()
			.find(|row| row["kind"] == "room" && row["directory"] == directory && row["publication"] == publication)
		{
			id = id_text(joined)?;
			return Ok(None);
		}
		Ok(Some(json!({"kind":"public-room", "base":base, "selection":selection})))
	})
	.await?;
	Ok(json!({"id":id}))
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
	// Reuse is keyed on the registration, so the case of a nickname or a
	// name another member took since cannot select the wrong conversation.
	let directory_id = id_text(&directory)?;
	let status = request(&options.state, json!({"verb":"status"})).await?;
	check_contact(&status, &directory)?;
	if let Some(row) = workspace::open_direct(&intent(&status)?, &directory_id, registration) {
		return text(&row.id);
	}
	let start = workspace::StartDirect {
		directory: &directory_id,
		peer,
		registration,
		opening: &super::operation()?,
	};
	// The admission keeps the introduced route through the shared plan, which
	// reopens the last closed conversation with this registration.
	super::admission::command_at(&setup(options), "startDirect", start.arguments(), status).await?;
	let opened = wait(options, "direct inbox", async |s| {
		Ok(intent(s).is_ok_and(|now| {
			workspace::open_direct(&now, &directory_id, registration).is_some_and(|row| row.inbox.is_some())
		}))
	})
	.await?;
	let opened = intent(&opened)?;
	let row = workspace::open_direct(&opened, &directory_id, registration)
		.ok_or_else(|| Failure::invalid("the direct conversation closed as it opened"))?;
	text(&row.id)
}
fn intent(status: &Value) -> Result<workspace::Intent, Failure> {
	workspace::Intent::decode(&status["workspace"].to_string())
		.map_err(|_| Failure::invalid("session returned an invalid workspace"))
}
fn text(id: &workspace::Id) -> Result<String, Failure> {
	id.text()
		.as_str()
		.map(str::to_owned)
		.ok_or_else(|| Failure::invalid("session response row lacks id text"))
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
