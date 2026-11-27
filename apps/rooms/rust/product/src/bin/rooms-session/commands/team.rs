//! Roster composition only. Every member uses the ordinary peer lifecycle and
//! application commands. Harness/model scheduling stays outside the product.
use super::{Failure, Options, execute, supervise};
use rooms_application::failure::Retry;
use rooms_application::room::inbox::{nick_key, nick_refusal};
use rooms_platform::storage::Directory;
use serde_json::{Value, json};
use std::collections::BTreeSet;

const ROSTER_LOCK: &str = "roster.lock";

pub async fn run(options: &Options) -> Result<Value, Failure> {
	match options.verb.as_str() {
		"team-start" => start(options).await,
		"team-status" | "team-stop" => {
			let root = options.state.clone();
			let stopping = options.verb == "team-stop";
			let (bytes, _lease) = tokio::task::spawn_blocking(move || {
				// A saved roster is immutable. Read it before taking the stop lease so
				// asking about an unknown team never creates its state directory.
				let bytes = rooms_platform::storage::read(&root.join("roster.json"), 16384)
					.map_err(|e| Failure::new("storage", Retry::AfterStateChange, e))?
					.ok_or_else(|| Failure::invalid("no roster in this directory"))?;
				let lease = stopping.then(|| Directory::open(root, ROSTER_LOCK)).transpose()?;
				Ok::<_, Failure>((bytes, lease))
			})
			.await
			.map_err(Failure::uncertain)??;
			let roster: Value = serde_json::from_slice(&bytes)?;
			let members = roster["members"]
				.as_array()
				.ok_or_else(|| Failure::invalid("roster lacks members"))?;
			let mut results = Vec::new();
			let verb = if stopping { "stop" } else { "status" };
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
		if let Some(reason) = nick_refusal(nick) {
			return Err(Failure::invalid(reason));
		}
		if !seen.insert(nick_key(nick)) {
			return Err(Failure::invalid(format!("duplicate roster nickname: {nick}")));
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
		let lease = Directory::open(root, ROSTER_LOCK)?;
		let old = rooms_platform::storage::read(&lease.path().join("roster.json"), 16384)
			.map_err(|e| Failure::new("storage", Retry::AfterStateChange, e))?;
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
		peer.named.insert("exact-nick".into(), vec!["true".into()]);
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

#[cfg(test)]
mod tests {
	use super::*;
	use rooms_testing::scratch::Scratch;

	fn options(root: &std::path::Path, verb: &str) -> Options {
		Options {
			verb: verb.into(),
			state: root.to_owned(),
			named: Default::default(),
			arguments: Vec::new(),
		}
	}

	#[tokio::test]
	async fn reserved_and_case_equivalent_members_fail_before_writing_a_roster() {
		let root = Scratch::new("team-nickname");
		let mut start = options(&root, "team-start");
		start.named.insert("lead".into(), vec!["Alice".into()]);
		start.named.insert("room".into(), vec!["workshop".into()]);
		start.named.insert("locator".into(), vec!["unused".into()]);
		for (nick, reason) in [
			("aLiCe", "duplicate roster nickname: aLiCe".to_owned()),
			("HERE", nick_refusal("HERE").unwrap()),
		] {
			start.named.insert("member".into(), vec![nick.into()]);
			assert_eq!(run(&start).await.unwrap_err().message, reason);
			assert!(!root.exists());
		}
	}

	#[tokio::test]
	async fn team_stop_needs_the_roster_lease_and_holds_it_while_stopping_a_peer() {
		let root = Scratch::new("team-stop");
		let stop = options(&root, "team-stop");
		assert_eq!(run(&stop).await.unwrap_err().message, "no roster in this directory");
		assert!(!root.exists());
		let lease = Directory::open(root.to_path_buf(), ROSTER_LOCK).unwrap();
		std::fs::write(root.join("roster.json"), br#"{"members":["Alice"]}"#).unwrap();
		assert_eq!(run(&stop).await.unwrap_err().class, "in-use");
		let status = run(&options(&root, "team-status")).await.unwrap();
		assert_eq!(status["members"][0]["nick"], "Alice");
		drop(lease);
		std::fs::create_dir(root.join("Alice")).unwrap();
		let socket = root.join("Alice/control.sock");
		let listener = tokio::net::UnixListener::bind(&socket).unwrap();
		let peer = async {
			use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
			let (stream, _) = listener.accept().await.unwrap();
			let mut stream = BufReader::new(stream);
			let mut line = String::new();
			stream.read_line(&mut line).await.unwrap();
			assert_eq!(serde_json::from_str::<Value>(&line).unwrap()["verb"], "stop");
			assert!(matches!(
				Directory::open(root.to_path_buf(), ROSTER_LOCK),
				Err(rooms_platform::storage::StorageError::InUse(_))
			));
			std::fs::remove_file(socket).unwrap();
			stream.get_mut().write_all(b"{\"ok\":true}\n").await.unwrap();
		};
		let (stopped, ()) = tokio::time::timeout(std::time::Duration::from_secs(3), async {
			tokio::join!(run(&stop), peer)
		})
		.await
		.unwrap();
		assert_eq!(stopped.unwrap()["ok"], true);
		Directory::open(root.to_path_buf(), ROSTER_LOCK).unwrap();
	}
}
