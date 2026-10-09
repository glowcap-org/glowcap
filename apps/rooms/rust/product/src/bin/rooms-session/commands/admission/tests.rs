//! Deterministic socket races exercise the CLI's actual automatic admission path.
use super::*;
use tokio::{
	io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
	net::UnixListener,
};

#[test]
fn direct_contact_retry_fences_registration_and_allows_standing_updates() {
	let original = json!({"directories":[{"id":"directory", "access":"access", "source":"source", "name":"name", "inbox":"inbox", "standing":"here"}]});
	let args = vec!["directory".into(), "peer".into(), "registration".into()];
	for field in ["id", "access", "source", "name", "inbox", "standing"] {
		let mut current = original.clone();
		current["directories"][0][field] = "replacement".into();
		assert_eq!(
			selection::unchanged("startDirect", &args, &original, &current),
			field == "standing",
			"{field}"
		);
	}
}

#[tokio::test]
async fn automatic_conflict_reprepares_only_unchanged_selection() {
	for change in ["none", "unrelated", "replacement", "membership", "source", "removed"] {
		let changed = !matches!(change, "none" | "unrelated");
		let state = std::env::temp_dir().join(format!(
			"rooms-admission-{}-{}",
			std::process::id(),
			operation().unwrap()
		));
		tokio::fs::create_dir(&state).await.unwrap();
		let listener = UnixListener::bind(state.join("control.sock")).unwrap();
		let options = Options {
			verb: "reply".into(),
			state: state.clone(),
			named: Default::default(),
			arguments: Vec::new(),
		};
		let server = tokio::spawn(async move {
			let workspace = json!({"conversations":[{"id":"conversation","kind":"room",
				"source":"original-source","access":"original-access","seat":"original-seat","draft":""}]});
			let mut requests = Vec::new();
			let steps = if changed { 4 } else { 7 };
			for step in 0..steps {
				let (stream, _) = listener.accept().await.unwrap();
				let mut reader = BufReader::new(stream);
				let mut line = String::new();
				reader.read_line(&mut line).await.unwrap();
				let request: Value = serde_json::from_str(&line).unwrap();
				let response = match step {
					0 => {
						assert_eq!(request["verb"], "status");
						json!({"ok":true,"revision":"1","workspace":workspace})
					}
					1 => {
						assert_eq!(request["verb"], "command");
						json!({"ok":true,"operation":request["id"],"status":"conflict"})
					}
					2 => {
						assert_eq!(request["verb"], "release-command");
						json!({"ok":true})
					}
					3 => {
						assert_eq!(request["verb"], "status");
						let mut current = workspace.clone();
						match change {
							"none" => {}
							"unrelated" => current["conversations"]
								.as_array_mut()
								.unwrap()
								.push(json!({"id":"another-room","seat":"installed-callback"})),
							"replacement" => current["conversations"][0]["access"] = "replacement".into(),
							"membership" => current["conversations"][0]["seat"] = "replacement".into(),
							"source" => current["conversations"][0]["source"] = "replacement".into(),
							"removed" => current["conversations"] = json!([]),
							_ => unreachable!(),
						}
						json!({"ok":true,"revision":"2","workspace":current})
					}
					4 => {
						assert_eq!(request["verb"], "command");
						json!({"ok":true,"operation":request["id"],"status":"committed"})
					}
					5 => {
						assert_eq!(request["verb"], "command-result");
						json!({"ok":true,"result":null})
					}
					6 => {
						assert_eq!(request["verb"], "release-command");
						json!({"ok":true})
					}
					_ => unreachable!(),
				};
				requests.push(request);
				let stream = reader.get_mut();
				stream.write_all(response.to_string().as_bytes()).await.unwrap();
				stream.write_all(b"\n").await.unwrap();
			}
			requests
		});
		let result = command(&options, "say", vec!["conversation".into(), "text".into()]).await;
		if !changed {
			assert_eq!(result.as_ref().unwrap()["status"], "committed");
		}
		let requests = tokio::time::timeout(Duration::from_secs(2), server)
			.await
			.unwrap()
			.unwrap();
		if changed {
			assert!(result.unwrap_err().message.contains("selection changed"));
		} else {
			assert_eq!(result.unwrap()["status"], "committed");
			assert_ne!(
				requests[1]["id"], requests[4]["id"],
				"known absence permits a new operation only"
			);
			assert_eq!(requests[1]["base"], 1);
			assert_eq!(requests[4]["base"], 2);
			assert_eq!(requests[1]["args"], requests[4]["args"]);
			assert_eq!(requests[4]["id"], requests[5]["id"]);
		}
		tokio::fs::remove_dir_all(state).await.unwrap();
	}
}
