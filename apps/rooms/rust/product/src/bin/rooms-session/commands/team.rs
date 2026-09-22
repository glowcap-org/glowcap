//! Roster composition only. Every member uses the ordinary peer lifecycle and
//! application commands. Harness/model scheduling stays outside the product.
use super::{Failure, Options, execute, supervise};
use serde_json::{Value, json};
use std::collections::BTreeSet;

pub async fn run(options: &Options) -> Result<Value, Failure> {
	match options.verb.as_str() {
		"team-start" => start(options).await,
		"team-status" | "team-stop" => {
			let path = options.state.join("roster.json");
			let bytes = tokio::task::spawn_blocking(move || rooms_platform::storage::read(&path, 16384))
				.await
				.map_err(Failure::uncertain)?
				.map_err(|e| Failure::new("storage", "after-state-change", e))?
				.ok_or_else(|| Failure::invalid("no roster in this directory"))?;
			let roster: Value = serde_json::from_slice(&bytes)?;
			let members = roster["members"]
				.as_array()
				.ok_or_else(|| Failure::invalid("roster lacks members"))?;
			let mut results = Vec::new();
			let verb = if options.verb == "team-stop" { "stop" } else { "status" };
			for member in members {
				let nick = member
					.as_str()
					.ok_or_else(|| Failure::invalid("invalid roster nickname"))?;
				let mut peer = options.clone();
				peer.verb = verb.into();
				peer.state = supervise::state_path(&options.state, nick)?;
				match execute(&peer).await {
                    Ok(status) if verb == "status" => results.push(json!({"nick":nick,"ok":true,"rooms":status["rooms"],
                        "issues":status["issues"],"inbox":status["inbox"],"pending_effects":status["pending_effects"].as_array().map(Vec::len)})),
                    Ok(result) => results.push(json!({"nick":nick,"ok":true,"result":result})),
                    Err(error) => results.push(json!({"nick":nick,"ok":false,"error":error})),
                }
			}
			Ok(json!({"ok":results.iter().all(|r|r["ok"] == true),"members":results}))
		}
		_ => Err(Failure::invalid("unknown team operation")),
	}
}
async fn start(options: &Options) -> Result<Value, Failure> {
	let lead = options
		.get("lead")
		.ok_or_else(|| Failure::invalid("--lead is required"))?;
	let mut nicks = vec![lead.to_owned()];
	nicks.extend(options.values("member"));
	let max = options.number("max", 4)?;
	if max == 0 || nicks.len() as u64 > max {
		return Err(Failure::exhausted("roster exceeds --max, including its lead"));
	}
	if nicks.len() < 2 {
		return Err(Failure::invalid("a team needs at least one --member"));
	}
	if nicks.len() > 64 {
		return Err(Failure::exhausted("roster exceeds 64 peers"));
	}
	let mut seen = BTreeSet::new();
	for nick in &nicks {
		supervise::state_path(&options.state, nick)?;
		if !seen.insert(nick) {
			return Err(Failure::invalid("roster nicknames must be distinct"));
		}
	}
	if options.values("room").is_empty() || options.get("locator").is_none() {
		return Err(Failure::invalid("team-start needs --room and --locator"));
	}
	let root = options.state.clone();
	let roster = json!({"lead":lead,"members":nicks,"rooms":options.values("room"),"locator":options.get("locator")});
	let encoded = serde_json::to_vec(&roster)?;
	if encoded.len() > 16384 {
		return Err(Failure::exhausted("roster exceeds its byte budget"));
	}
	let lease = tokio::task::spawn_blocking(move || {
		let lease = rooms_platform::storage::Directory::open(root, "roster.lock")?;
		let old = rooms_platform::storage::read(&lease.path().join("roster.json"), 16384)
			.map_err(|e| Failure::new("storage", "after-state-change", e))?;
		if let Some(old) = old {
			if serde_json::from_slice::<Value>(&old)? != serde_json::from_slice::<Value>(&encoded)? {
				return Err(Failure::invalid(
					"this directory owns a different roster; use its existing roster or a new --dir",
				));
			}
		} else {
			rooms_platform::storage::atomic::replace(&lease, "roster.json", [&encoded[..]])
				.map_err(|e| Failure::uncertain(format!("{e:?}")))?;
		}
		Ok::<_, Failure>(lease)
	})
	.await
	.map_err(Failure::uncertain)??;
	let mut started = Vec::new();
	for nick in &nicks {
		let mut peer = options.clone();
		peer.verb = "start".into();
		peer.state = supervise::state_path(&options.state, nick)?;
		peer.named.insert("nick".into(), vec![nick.clone()]);
		if let Err(mut error) = supervise::start(&peer).await {
			error.message = format!(
				"starting {nick}: {}; already started: {}; those peers remain available through team-status/team-stop",
				error.message,
				started.join(", ")
			);
			return Err(error);
		}
		started.push(nick.clone());
	}
	drop(lease);
	Ok(
		json!({"ok":true,"lead":lead,"members":nicks,"rooms":options.values("room"),
        "directory":options.state,"hint":"Run one model consumer per member using rooms-peer tick or listen. Starting peers does not start models."}),
	)
}
