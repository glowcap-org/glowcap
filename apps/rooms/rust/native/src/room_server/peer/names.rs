//! Hold the actual authority writer between preparation and disk I/O.
//! Names must exclude competing publication during the wait and uncertainty.
use super::*;
use glowcap::Argument;
use rooms_application::{room::policy::RoomPolicy, server::links::Registration};
use std::{path::PathBuf, time::Duration};

struct Temp(PathBuf);
impl Drop for Temp {
	fn drop(&mut self) {
		let _ = std::fs::remove_dir_all(&self.0);
	}
}

#[test]
fn pending_room_names_survive_the_write_wait_and_uncertain_replacement() {
	let runtime = tokio::runtime::Builder::new_current_thread()
		.enable_all()
		.max_blocking_threads(1)
		.build()
		.unwrap();
	tokio::task::LocalSet::new().block_on(&runtime, async {
		tokio::time::timeout(Duration::from_secs(30), scenario()).await.unwrap();
	});
}

const ID: &str = "~1234567890abcdef1234567890abcdef";

async fn scenario() {
	let temp = Temp(std::env::temp_dir().join(format!("rooms-pending-names-{}", std::process::id())));
	std::fs::create_dir(&temp.0).unwrap();
	let config = Config::parse(
		[format!("--state={}", temp.0.display()), "--transport=tcp".into()],
		|_| None,
	)
	.unwrap()
	.unwrap();
	let mut peer = Peer::open(config, Rc::new(|_| {})).await.unwrap();
	let shared = peer.state.clone();
	let writer = peer.owners.authority.take().unwrap();
	let writing = tokio::task::spawn_local(writer.run(shared.clone()));
	let created = authority::queue::request(
		&shared.borrow(),
		"roomAuthorities",
		|state| {
			Ok(state.authority.remembered(
				ID,
				false,
				true,
				None,
				Some(Registration {
					name: "original",
					policy: RoomPolicy::Open,
				}),
			)?)
		},
		|_| Ok(Argument::Void),
	);
	created.await.unwrap();

	// Occupy the only blocking worker. Its sender is dropped on panic too,
	// so the test runtime can always shut down without a stranded worker.
	let (release, held) = std::sync::mpsc::channel::<()>();
	let (entered, ready) = tokio::sync::oneshot::channel();
	let blocking = tokio::task::spawn_blocking(move || {
		entered.send(()).unwrap();
		let _ = held.recv();
	});
	ready.await.unwrap();
	let (prepared, pending) = tokio::sync::oneshot::channel();
	let renamed = authority::queue::request(
		&shared.borrow(),
		"setRoomPolicy",
		move |state| {
			prepared.send(()).unwrap();
			Ok(state
				.authority
				.with_managed_room_policy(ID, "net/#renamed", RoomPolicy::Open)?)
		},
		|_| Ok(Argument::Void),
	);
	let renamed = tokio::task::spawn_local(renamed);
	pending.await.unwrap();
	{
		let state = shared.borrow();
		assert_eq!(state.authority.managed_room(ID).unwrap().name, "original");
		assert!(state.native_name_taken("ORIGINAL"));
		assert!(state.native_name_taken("NET/#RENAMED"));
		assert!(!state.native_name_taken(ID));
	}
	release.send(()).unwrap();
	blocking.await.unwrap();
	renamed.await.unwrap().unwrap();
	assert!(!shared.borrow().native_name_taken("original"));
	assert!(shared.borrow().native_name_taken("net/#renamed"));
	assert!(!shared.borrow().authority_writer.holds_name("net/#renamed"));

	let file = temp.0.join(rooms_application::server::document::FILE);
	let saved = temp.0.join("rooms.saved");
	std::fs::rename(&file, &saved).unwrap();
	std::fs::create_dir(&file).unwrap();
	let uncertain = authority::queue::request(
		&shared.borrow(),
		"setRoomPolicy",
		|state| {
			Ok(state
				.authority
				.with_managed_room_policy(ID, "uncertain", RoomPolicy::Open)?)
		},
		|_| Ok(Argument::Void),
	);
	assert!(uncertain.await.unwrap_err().contains("write is uncertain"));
	assert!(shared.borrow().native_name_taken("uncertain"));
	assert!(shared.borrow().native_name_taken("net/#renamed"));
	let refused = authority::queue::request(
		&shared.borrow(),
		"roomAuthorities",
		|_| panic!("stale preparation ran"),
		|_| Ok(Argument::Void),
	);
	assert!(refused.await.unwrap_err().contains("requires restart reconciliation"));
	assert!(shared.borrow().native_name_taken("uncertain"));
	std::fs::remove_dir(&file).unwrap();
	std::fs::rename(&saved, &file).unwrap();
	shared.borrow().authority_writer.stop();
	writing.await.unwrap();
	drop(shared);
	peer.close().await.unwrap();
}
