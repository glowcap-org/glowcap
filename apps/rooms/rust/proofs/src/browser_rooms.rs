//! Shared multi-room execution against the native directory in Chromium.
use rooms_application::{
	documents::SessionDocument,
	files::{CHUNK_BYTES, FileDescription},
	session::checkpoint::{
		commands::{Command, CommandRoutes},
		reconciliation::Id,
	},
};
use rooms_browser::platform::Platform;
use rooms_glowcap::client::sources::Source;
use rooms_runtime::{
	directories::runtime::DirectoryRuntime,
	documents::VolatileDocument,
	rooms::{ConversationEvent, Events, RoomRuntime},
	session::{bridge_secrets::BridgeSecrets, commands::SessionCommands},
};

pub async fn exercise(
	directories: DirectoryRuntime<Platform>,
	commands: SessionCommands,
	directory: &Id,
	location: &str,
) {
	let platform = Platform::new().unwrap();
	let bridge_secrets = BridgeSecrets::open(VolatileDocument::new(SessionDocument::BridgeSecrets))
		.await
		.unwrap();
	let (rooms, worker, mut events) = RoomRuntime::open(
		platform.clone(),
		platform.clone(),
		directories.clone(),
		commands.clone(),
		bridge_secrets,
		None,
	)
	.unwrap();
	let execute = async {
		for name in ["wasm-runtime-alpha", "wasm-runtime-beta"] {
			command(
				&commands,
				name,
				Command::JoinRoom,
				vec![
					serde_json::json!({
						"locator":location,"nick":"shared-runtime","conversation":{
							"kind":"room","id":name,"directory":directory.text().as_str().unwrap(),
							"name":name,"held":false,"standing":null,"draft":""
						}
					})
					.to_string()
					.into(),
				],
			)
			.await;
		}
		let mut changes = rooms.changes();
		loop {
			changes.borrow_and_update();
			if rooms.connected("wasm-runtime-alpha") && rooms.connected("wasm-runtime-beta") {
				break;
			}
			assert!(rooms.issues().is_empty(), "room realization: {:?}", rooms.issues());
			changes.changed().await.unwrap();
		}
		assert_ne!(
			rooms.live("wasm-runtime-alpha").unwrap().reference(),
			rooms.live("wasm-runtime-beta").unwrap().reference()
		);
		let snapshot = rooms_runtime::session::projection::current(
			&commands.view(),
			location,
			&directories.read(),
			&rooms,
			&[],
			&[],
			&[],
		)
		.unwrap();
		assert_eq!(snapshot.connected_directories.as_slice().len(), 1);
		assert_eq!(snapshot.room_views.as_slice().len(), 2);
		let projected = snapshot
			.project::<rooms_glowcap::snapshot::Arguments>(rooms_application::grants::Access::Observe, &"".into(), &[])
			.unwrap();
		let projected = rooms_application::session::snapshot::Snapshot::read(
			&projected.iter().map(rooms_glowcap::Value).collect::<Vec<_>>(),
			&rooms_glowcap::routes::CheckpointRoutes,
		)
		.unwrap();
		assert_eq!(projected.access, rooms_application::grants::Access::Observe);
		assert_eq!(projected.room_views.as_slice().len(), 2);
		let operations = rooms_runtime::rooms::operations::Operations::new(platform.clone());
		operations.reconcile(&commands, &directories);
		let peering = rooms_runtime::rooms::peering::Peering::new(platform.clone());
		peering.reconcile(&commands, &directories, &rooms);
		let alpha = rooms.live("wasm-runtime-alpha").unwrap();
		assert!(alpha.stewardship().claim().await.unwrap());
		let bytes = vec![41u8; CHUNK_BYTES + 17];
		let source = Source::bytes(
			FileDescription::new(
				"shared-room".into(),
				"application/octet-stream".into(),
				bytes.len() as u64,
				0,
				0,
			)
			.unwrap(),
			bytes.clone(),
		)
		.unwrap();
		assert!(
			rooms
				.send_files("wasm-runtime-alpha", "first shared room file", vec![source])
				.await
				.is_ok()
		);
		let first = message(&mut events, "first shared room file").await;
		assert_eq!(first.conversation_id, "wasm-runtime-alpha");
		assert!(first.editable);
		let file = first.files[0].materialize().await.unwrap();
		assert_eq!(file.read(0, CHUNK_BYTES).unwrap(), bytes[..CHUNK_BYTES]);
		assert_eq!(file.read(CHUNK_BYTES as u64, 17).unwrap(), bytes[CHUNK_BYTES..]);
		let manager = alpha.stewardship().links().manager.unwrap();
		let token = rooms_glowcap::routes::CheckpointRoutes
			.authority_token(&manager)
			.unwrap();
		command(
			&commands,
			"drop-shared-alpha-manager",
			Command::DropRoomManager,
			vec!["wasm-runtime-alpha".into(), token.into()],
		)
		.await;
		loop {
			changes.borrow_and_update();
			let held = rooms.live("wasm-runtime-alpha").unwrap();
			assert!(
				std::rc::Rc::ptr_eq(&alpha, &held),
				"authority rotation replaced the membership"
			);
			if !held
				.stewardship()
				.retains(rooms_application::room::stewardship::Kind::Manager, &manager)
			{
				break;
			}
			changes.changed().await.unwrap();
		}
		assert!(
			rooms
				.edit("wasm-runtime-alpha", first.line_id.unwrap(), "edited shared room file")
				.await
				.is_ok()
		);
		let edited = message(&mut events, "edited shared room file").await;
		let same = edited.files[0].materialize().await.unwrap();
		assert_eq!(
			file.span(0, 3).unwrap().as_ref().as_ptr(),
			same.span(0, 3).unwrap().as_ref().as_ptr()
		);
		assert!(
			rooms
				.withdraw("wasm-runtime-alpha", first.line_id.unwrap())
				.await
				.is_ok()
		);
		command(
			&commands,
			"leave-shared-alpha",
			Command::LeaveConversation,
			vec!["wasm-runtime-alpha".into()],
		)
		.await;
		loop {
			changes.borrow_and_update();
			if !rooms.connected("wasm-runtime-alpha") {
				break;
			}
			changes.changed().await.unwrap();
		}
		assert!(rooms.say("wasm-runtime-beta", "sibling room survives").await.is_ok());
		assert_eq!(
			message(&mut events, "sibling room survives").await.conversation_id,
			"wasm-runtime-beta"
		);
		// Fill the event stream without reading it. Shutdown must wake the
		// membership pump even while an attached view has stopped consuming.
		for index in 0..300 {
			rooms
				.say("wasm-runtime-beta", "unconsumed event")
				.await
				.unwrap_or_else(|error| panic!("unconsumed event {index}: {}", rooms_runtime::Error::from(error)));
		}
		rooms.close().await.unwrap();
		assert!(!rooms.connected("wasm-runtime-beta"));
		assert_eq!(file.read(0, 3).unwrap(), [41, 41, 41]);
	};
	let (result, ()) = tokio::join!(worker.run(), execute);
	result.unwrap();
}
async fn message(events: &mut Events, text: &str) -> ConversationEvent {
	loop {
		let event = events.next().await.unwrap();
		if event.text == text {
			return event;
		}
	}
}
async fn command(
	commands: &SessionCommands,
	operation: &str,
	command: Command,
	args: Vec<rooms_application::text::DocumentText>,
) {
	let base = commands.view().read(|state| state.revision().unwrap()).unwrap();
	commands
		.prepare_command(
			rooms_application::fields::Text::new(operation.into()).unwrap(),
			base,
			command,
			args,
		)
		.unwrap()
		.send()
		.unwrap()
		.wait()
		.await
		.unwrap();
}
