//! A held room manager cannot act on another room's known authority tokens.
use super::*;
use rooms_application::{
	directory::creation::RecoveryKey,
	room::{authority, policy::RoomPolicy},
	session::checkpoint::commands::CommandRoutes,
};
use rooms_glowcap::{
	client::{Client, directory::Directory},
	routes::CheckpointRoutes,
};

#[tokio::test]
async fn manager_refuses_sibling_tokens_without_changing_persisted_authority() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(15), scenario())
				.await
				.expect("scoped manager deadline");
		})
		.await;
}
async fn scenario() {
	let temp = Temp::new();
	let running = super::super::start(temp.0.clone(), tcp()).await;
	let runtime = runtime().await;
	let session = runtime
		.connect(
			&glowcap::parse_locator(&running.location).unwrap(),
			ConnectOptions::default(),
		)
		.await
		.unwrap();
	let directory = Directory::fetch(Client::new(session.borrowed(), rooms_platform::HostPlatform))
		.await
		.unwrap();
	let left = directory
		.open_managed("Left", RoomPolicy::Open, &RecoveryKey::from_entropy([41; 16]))
		.await
		.unwrap();
	let right = directory
		.open_managed("Right", RoomPolicy::Open, &RecoveryKey::from_entropy([42; 16]))
		.await
		.unwrap();
	let manager = session.enliven(&left.manager_link).await.unwrap();
	let other = session.enliven(&right.manager_link).await.unwrap();
	let grant = session.send(&other, authority::GIVE_STEWARD, &[]).await.unwrap();
	let steward_uri = grant.as_list().unwrap()[2].as_str().unwrap();
	let tokens = [
		CheckpointRoutes.authority_token(&right.room_link).unwrap(),
		CheckpointRoutes.authority_token(steward_uri).unwrap(),
		CheckpointRoutes.authority_token(&right.manager_link).unwrap(),
	];
	let document = temp.0.join(rooms_application::server::document::FILE);
	let original = std::fs::read(&document).unwrap();
	for (verb, args) in [
		(authority::REVOKE_ROOM_LINK, vec![tokens[0].clone().into()]),
		(authority::REVOKE_STEWARD, vec![tokens[1].clone().into()]),
		(authority::UNREGISTER_ROOM, vec![tokens[2].clone().into()]),
		(
			authority::SET_POLICY,
			vec![
				tokens[2].clone().into(),
				"listed".into(),
				"open".into(),
				"open".into(),
				"Renamed".into(),
			],
		),
	] {
		let error = session.send(&manager, verb, &args).await.unwrap_err();
		let reason = if matches!(verb, authority::REVOKE_ROOM_LINK | authority::REVOKE_STEWARD) {
			"different room"
		} else {
			"takes"
		};
		assert!(error.to_string().contains(reason), "{verb}: {error}");
		assert_eq!(
			std::fs::read(&document).unwrap(),
			original,
			"refusal writes no authority"
		);
	}
	let [visibility, entry, speaking] = RoomPolicy::Moderated.modes();
	let update = session
		.send(
			&manager,
			authority::SET_POLICY,
			&[visibility.into(), entry.into(), speaking.into(), "Left renamed".into()],
		)
		.await
		.unwrap();
	assert_eq!(update.as_list().unwrap()[0].as_str(), Some("Left renamed"));
	session.send(&manager, authority::UNREGISTER_ROOM, &[]).await.unwrap();
	// The right manager still acts on its own exact tokens, after the sibling's
	// public rename and unregistration. Shared transport remains usable.
	session
		.send(&other, authority::REVOKE_STEWARD, &[tokens[1].clone().into()])
		.await
		.unwrap();
	session
		.send(&other, authority::REVOKE_ROOM_LINK, &[tokens[0].clone().into()])
		.await
		.unwrap();
	session.close(PendingWork::Cancel).await.unwrap();
	running.stop.send(()).unwrap();
	running.task.await.unwrap().unwrap();
	runtime.close(PendingWork::Cancel).await.unwrap();
}
