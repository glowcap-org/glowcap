//! Named contact selection refuses local registration replacement during lookup.
use super::*;
use tokio::{
	io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
	net::UnixListener,
};

#[tokio::test]
async fn named_contact_fences_lookup_before_reusing_route() {
	for change in ["none", "access", "source", "name", "inbox", "removed"] {
		let state = std::env::temp_dir().join(format!(
			"rooms-contact-{}-{}",
			std::process::id(),
			super::super::operation().unwrap()
		));
		tokio::fs::create_dir(&state).await.unwrap();
		let listener = UnixListener::bind(state.join("control.sock")).unwrap();
		let options = Options {
			verb: "reply".into(),
			state: state.clone(),
			named: [("dm".into(), vec!["Bob".into()])].into(),
			arguments: Vec::new(),
		};
		let server = tokio::spawn(async move {
			let key = "00000000000000010000000000000001";
			let directory = json!({"id":"directory", "home":true, "access":key, "source":key, "name":key, "inbox":key});
			let mut workspace = json!({"directories":[directory], "conversations":[{
				"kind":"direct", "id":"direct", "directory":"directory", "peer":"Bob", "closed":false,
				"introduction":{"access":key, "name":key, "callback":key, "registration":"peer"}
			}]});
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
						workspace["directories"][0][change] = "replacement".into();
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
		tokio::fs::remove_dir_all(state).await.unwrap();
	}
}
