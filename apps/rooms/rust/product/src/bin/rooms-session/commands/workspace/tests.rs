//! Named contact selection refuses local registration replacement during
//! lookup, and reuses an open conversation by the registration it names.
use super::*;
use tokio::{
	io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
	net::UnixListener,
};

#[tokio::test]
async fn named_contact_fences_lookup_before_reusing_route() {
	for change in ["none", "access", "source", "name", "inbox", "removed"] {
		let state = rooms_testing::scratch::Scratch::create("contact");
		let listener = UnixListener::bind(state.join("control.sock")).unwrap();
		let options = Options {
			verb: "reply".into(),
			state: state.to_path_buf(),
			named: [("dm".into(), vec!["Bob".into()])].into(),
			arguments: Vec::new(),
		};
		let server = tokio::spawn(async move {
			let key = "00000000000000010000000000000001";
			let directory = json!({"id":"directory", "home":true, "access":key, "source":key, "name":key, "inbox":key,
				"nick":"me", "nickAllocation":"exact", "standing":null});
			// The open row is held under another nickname case, and reuse
			// still finds it by registration.
			let mut workspace = json!({"version":1, "directories":[directory], "conversations":[{
				"kind":"direct", "id":"direct", "directory":"directory", "peer":"bob", "closed":false,
				"access":key, "source":key, "draft":"",
				"introduction":{"access":key, "name":key, "callback":key, "registration":"peer", "opening":"o"}
			}], "invitations":[], "active":null, "standing":"", "ignored":[], "keepHistory":false,
				"connection":"fastest", "archive":null, "archiveControl":null, "operators":[], "peering":[]});
			for verb in ["status", "status", "status", "directory-read", "status"] {
				let (stream, _) = listener.accept().await.unwrap();
				let mut reader = BufReader::new(stream);
				let mut line = String::new();
				reader.read_line(&mut line).await.unwrap();
				let request: Value = serde_json::from_str(&line).unwrap();
				assert_eq!(request["verb"], verb);
				let response = if verb == "directory-read" {
					if change == "removed" {
						workspace["directories"] = json!([]);
					} else if change != "none" {
						workspace["directories"][0][change] = "00000000000000020000000000000001".into();
					}
					json!({"ok":true, "registration":"peer"})
				} else {
					json!({"ok":true, "revision":"1", "workspace":workspace})
				};
				reader
					.get_mut()
					.write_all(format!("{response}\n").as_bytes())
					.await
					.unwrap();
			}
		});
		let selected = target(&options).await;
		if change == "none" {
			assert_eq!(selected.unwrap(), "direct");
		} else {
			assert!(selected.unwrap_err().message.contains("initiating"));
		}
		tokio::time::timeout(Duration::from_secs(2), server)
			.await
			.unwrap()
			.unwrap();
	}
}

#[tokio::test]
async fn concurrent_listed_room_join_adopts_the_conversation_installed_at_the_next_revision() {
	let state = rooms_testing::scratch::Scratch::create("concurrent-join");
	let listener = UnixListener::bind(state.join("control.sock")).unwrap();
	let options = Options {
		verb: "join".into(),
		state: state.to_path_buf(),
		named: Default::default(),
		arguments: Vec::new(),
	};
	let room = |directory, publication, id| json!({"kind":"room","directory":directory,"publication":publication,"id":id,"name":"workshop"});
	let other_rows = [
		room("other", "listed", "other-room"),
		room("directory", "old-edition", "old-room"),
	];
	let mut joined = other_rows.to_vec();
	joined.push(room("directory", "listed", "winning-conversation"));
	let server = async {
		let steps = [
			(
				"status",
				json!({"ok":true,"revision":"1","workspace":{"conversations":other_rows}}),
			),
			(
				"acquire",
				Failure::conflict("another join installed the publication").response(),
			),
			("release-acquisition", json!({"ok":true})),
			(
				"status",
				json!({"ok":true,"revision":"2","workspace":{"conversations":joined}}),
			),
		];
		for (verb, response) in steps {
			let (stream, _) = listener.accept().await.unwrap();
			let mut stream = BufReader::new(stream);
			let mut line = String::new();
			stream.read_line(&mut line).await.unwrap();
			let request: Value = serde_json::from_str(&line).unwrap();
			assert_eq!(request["verb"], verb);
			if verb == "acquire" {
				assert_eq!(request["request"]["selection"]["publication"], "listed");
				assert_eq!(request["request"]["base"], 1);
			}
			stream
				.get_mut()
				.write_all(format!("{response}\n").as_bytes())
				.await
				.unwrap();
		}
	};
	let directory = json!({"id":"directory"});
	let listing = json!({"name":"workshop","id":"listed"});
	let joining = join_listed_room(&options, &directory, &listing);
	let (result, ()) = tokio::time::timeout(Duration::from_secs(2), async { tokio::join!(joining, server) })
		.await
		.unwrap();
	assert_eq!(result.unwrap()["id"], "winning-conversation");
}
