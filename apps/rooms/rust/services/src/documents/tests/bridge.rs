//! The production credential file recovers witnessed custody in a fresh process.
use super::*;
use rooms_application::bridge::Answers;
use rooms_runtime::session::bridge_secrets::BridgeSecrets;

#[tokio::test]
async fn bridge_credentials_recover_and_forget_across_processes() {
	if let Some(path) = std::env::var_os("GLOWCAP_BRIDGE_CREDENTIAL_PROOF_PATH") {
		let directory = Arc::new(Directory::open(path.into(), ".rooms-managed.lock").unwrap());
		let journal = BridgeSecrets::open(DocumentFile::bridge_secrets(directory))
			.await
			.unwrap();
		let owner: rooms_application::text::DocumentText = "0123456789abcdef0123456789abcdef".into();
		let key: rooms_application::text::DocumentText = "0000000000000001".into();
		let nonce: rooms_application::text::DocumentText = "fedcba9876543210fedcba9876543210".into();
		journal.bind_owner(&owner).await.unwrap();
		match std::env::var("GLOWCAP_BRIDGE_CREDENTIAL_PROOF_PHASE").unwrap().as_str() {
			"stage" => {
				journal
					.stage(
						owner.clone(),
						key.clone(),
						Answers::decode("{\"password\":\"retained credential\"}").unwrap(),
						Some(nonce.clone()),
					)
					.await
					.unwrap();
				journal
					.stage(
						owner.clone(),
						"0000000000000002".into(),
						Answers::decode("{\"password\":\"orphan credential\"}").unwrap(),
						Some(nonce.clone()),
					)
					.await
					.unwrap();
				// No application settlement or journal recovery occurs in this
				// process. The next process observes the actual durable candidates.
			}
			"recover" => {
				assert!(
					journal
						.bind_owner(&"ffffffffffffffffffffffffffffffff".into())
						.await
						.is_err()
				);
				journal
					.recover(&[(owner.clone(), key.clone(), Some(nonce.clone()))])
					.await
					.unwrap();
				let (answers, revision) = journal.answers(&owner, &key).await.unwrap().unwrap();
				assert_eq!(answers.get("password").unwrap().as_str(), Some("retained credential"));
				assert_eq!(revision, Some(nonce));
				assert!(
					journal
						.answers(&owner, &"0000000000000002".into())
						.await
						.unwrap()
						.is_none()
				);
				journal.retain_witnesses(&[]).await.unwrap();
				assert!(journal.answers(&owner, &key).await.unwrap().is_none());
			}
			"forgotten" => {
				assert!(journal.answers(&owner, &key).await.unwrap().is_none());
				let bytes = fs::read_to_string(
					std::path::Path::new(&std::env::var_os("GLOWCAP_BRIDGE_CREDENTIAL_PROOF_PATH").unwrap())
						.join("bridge-secrets.json"),
				)
				.unwrap();
				assert!(
					!bytes.contains("credential"),
					"forgetting removes the physical secret bytes"
				);
			}
			_ => panic!("unknown credential recovery phase"),
		}
		return;
	}
	let temp = Temp::new();
	for phase in ["stage", "recover", "forgotten"] {
		let mut child = std::process::Command::new(std::env::current_exe().unwrap())
			.args(["bridge_credentials_recover_and_forget_across_processes", "--nocapture"])
			.env("GLOWCAP_BRIDGE_CREDENTIAL_PROOF_PATH", temp.state())
			.env("GLOWCAP_BRIDGE_CREDENTIAL_PROOF_PHASE", phase)
			.spawn()
			.unwrap();
		let outcome = tokio::time::timeout(std::time::Duration::from_secs(10), async {
			loop {
				if let Some(status) = child.try_wait().unwrap() {
					break status;
				}
				tokio::time::sleep(std::time::Duration::from_millis(10)).await;
			}
		})
		.await;
		if outcome.is_err() {
			child.kill().unwrap();
			child.wait().unwrap();
		}
		assert!(
			outcome.expect("credential recovery child deadline").success(),
			"credential {phase}"
		);
	}
}
