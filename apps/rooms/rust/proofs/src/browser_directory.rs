//! Shared directory supervision against the native server reached by Chromium.
#[path = "browser_rooms.rs"]
mod room_execution;
use rooms_application::{
	grants::Access,
	session::checkpoint::{commands::Command, reconciliation::Id, Checkpoint, Routes},
};
use rooms_browser::platform::Platform;
use rooms_glowcap::{client::directory::Directory, routes::CheckpointRoutes};
use rooms_runtime::{
	directory_runtime::{DirectoryRuntime, Phase},
	documents::VolatileDocuments,
	session_commands::SessionCommands,
	session_state::DurableSession,
};
use std::rc::Rc;

pub async fn exercise(transport: Rc<glowcap::Runtime>, directory: Directory<Platform>, location: &str) {
	let advertised = directory.advertised_location().await.unwrap();
	let id = CheckpointRoutes.locator_authority(location).unwrap();
	let mut value: serde_json::Value =
		serde_json::from_str(&Checkpoint::empty().encode_for(Access::Admin).unwrap()).unwrap();
	value["directories"] = serde_json::json!([{
		"id":id,"locator":location,"home":true,"nick":"shared-runtime","standing":null
	}]);
	let material = value.to_string();
	let checkpoint = Checkpoint::decode(&material, &CheckpointRoutes).unwrap();
	let platform = directory.client().platform().clone();
	let mut state = DurableSession::new(VolatileDocuments::default(), platform.clone());
	assert!(matches!(
		state.load().await.unwrap(),
		rooms_runtime::session_state::LoadStatus::Ready
	));
	state
		.adopt(
			rooms_application::fields::Text::new("adopt-browser-directory".into()).unwrap(),
			0,
			&material.into(),
			checkpoint,
		)
		.await
		.unwrap();
	let (commands, command_worker) = SessionCommands::open(state, platform.clone()).await.unwrap();
	let member = glowcap::format_locator_uri(&glowcap::Locator::bare(
		glowcap::TRANSPORT_WEBRTC,
		&directory.client().session().host().designator().unwrap(),
	))
	.unwrap();
	let (runtime, directory_worker, events, inbox) =
		DirectoryRuntime::new(transport, commands.clone(), member, platform.clone(), platform).unwrap();
	let id = Id::new(id.into()).unwrap();
	runtime
		.adopt(id.text(), directory.clone(), "shared-runtime".into())
		.unwrap();
	let execute = async {
		let mut changes = runtime.changes();
		loop {
			changes.borrow_and_update();
			if runtime.connected(&id).is_some() {
				break;
			}
			for row in runtime.read().rows() {
				assert!(row.issue().is_none(), "directory realization: {:?}", row.issue());
			}
			changes.changed().await.unwrap();
		}
		{
			let directories = runtime.read();
			let row = &directories.rows()[0];
			assert_eq!(row.phase(), Phase::Connected);
			let live = row.live().unwrap();
			assert_eq!(live.directory().reference(), directory.reference());
			assert!(live.view().room_named(&"rust-browser-one".into()).is_some());
		}
		let saved = commands
			.view()
			.read(|state| state.checkpoint().unwrap().encode_for(Access::Admin).unwrap())
			.unwrap();
		let saved: serde_json::Value = serde_json::from_str(&saved).unwrap();
		assert_eq!(saved["directories"][0]["reached"], true);
		assert!(runtime.read().fact_issues().next().is_none());
		room_execution::exercise(runtime.clone(), commands.clone(), &id, location).await;
		let base = commands.view().read(|state| state.revision().unwrap()).unwrap();
		commands
			.prepare_command(
				rooms_application::fields::Text::new("leave-browser-directory".into()).unwrap(),
				base,
				Command::LeaveDirectory,
				vec![id.text().clone()],
			)
			.unwrap()
			.send()
			.unwrap()
			.wait()
			.await
			.unwrap();
		// Committed removal retires authority before the command is acknowledged.
		assert!(runtime.connected(&id).is_none());
		loop {
			changes.borrow_and_update();
			if runtime.read().rows().is_empty() {
				break;
			}
			changes.changed().await.unwrap();
		}
		runtime.close().await.unwrap();
		assert!(runtime.is_closed());
		assert!(runtime
			.adopt(id.text(), directory.clone(), "shared-runtime".into())
			.is_err());
		// Retiring this owner's watches leaves the sibling client and room usable.
		assert_eq!(directory.advertised_location().await.unwrap(), advertised);
		commands.close().await.unwrap();
	};
	let (run_commands, run_directories, ()) =
		tokio::join!(command_worker.run(events), directory_worker.run(), execute,);
	run_commands.unwrap();
	run_directories.unwrap();
	drop(inbox);
}
