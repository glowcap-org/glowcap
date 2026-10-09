//! Creation preserves intervening edits and refuses a replaced directory.
use super::*;
use rooms_glowcap::client::workspace::{ResultImport, Workspace};

pub(super) async fn run(
	host: &Host,
	owner: &managed::Session<Platform>,
	root: &Ref,
	canonical: &str,
	intent: &mut Intent,
) {
	let workspace = Workspace::local(host.clone(), Platform::default(), root.clone());
	let (id, base, name, args): (String, u64, String, Vec<String>) = serde_json::from_str(canonical).unwrap();
	let command = workspace.prepare_command(&id, base, &name, &args).await.unwrap();
	let snapshot = workspace.snapshot().await.unwrap();
	let mut candidate = snapshot.intent;
	let room: session::workspace::Room = serde_json::from_value(serde_json::json!({
		"kind": "room", "id": "created", "directory": "directory", "name": "New room",
		"access": "00000000000000090000000000000001",
		"control": "00000000000000090000000000000001",
		"source": "00000000000000090000000000000001",
		"reconnect": "requested", "standing": null, "draft": ""
	}))
	.unwrap();
	let source = room.source.unwrap();
	candidate
		.conversations
		.try_push(session::workspace::Conversation::Room(Box::new(room)))
		.unwrap();
	let mappings = [custody::Role::RoomAccess, custody::Role::RoomControl].map(|role| ResultImport {
		result: coordinate(role),
		destination: custody::Coordinate {
			role,
			key: custody::FieldKey::new(source.slot(), source.generation()),
		},
	});
	let acquisition = command
		.prepare_result_acquisition_with_source(snapshot.revision, &mappings, &[], &candidate, Some(source))
		.unwrap()
		.created_room()
		.unwrap();
	assert!(
		acquisition.submit().await.is_err(),
		"replacement directory cannot adopt the original result"
	);
	assert_eq!(workspace.snapshot().await.unwrap().revision, snapshot.revision);
	intent.directories.as_mut_slice()[0].access = key();
	for index in 0..6 {
		intent.standing = rooms_application::fields::Text::new(format!("intervening edit {index}").into()).unwrap();
		owner.replace_workspace(intent).await.unwrap();
	}
	acquisition.submit().await.unwrap();
	let adopted = workspace.snapshot().await.unwrap();
	assert_eq!(
		adopted.intent.standing, intent.standing,
		"append preserves every newer workspace field"
	);
	assert_eq!(adopted.intent.directories, intent.directories);
	assert_eq!(adopted.intent.conversations.as_slice().len(), 1);
	assert_eq!(adopted.intent.active.as_ref().unwrap().text().as_str(), Some("created"));
	acquisition.submit().await.unwrap();
	assert_eq!(workspace.snapshot().await.unwrap().revision, adopted.revision);
	owner.replace_workspace(intent).await.unwrap();
	let retired = workspace.snapshot().await.unwrap();
	acquisition.submit().await.unwrap();
	assert_eq!(
		workspace.snapshot().await.unwrap().revision,
		retired.revision,
		"replay cannot resurrect a retired room"
	);
}
