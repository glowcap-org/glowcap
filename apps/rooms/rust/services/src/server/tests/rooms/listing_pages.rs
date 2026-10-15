//! The directory's one-shot listing walks by cursor: a page boundary falls
//! inside a live listing, and a room that closes between two pages moves no
//! other row.
use super::*;
use rooms_application::directory::{LIST, MAX_ROWS};
use std::collections::{BTreeMap, BTreeSet};

#[tokio::test]
async fn a_listing_walk_crosses_a_page_boundary_while_a_room_closes() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(60), walk())
				.await
				.expect("listing walk deadline");
		})
		.await;
}

async fn walk() {
	let temp = Temp::new();
	// Two creators each open half the rooms, inside the per-creator cap,
	// with room creation admitted faster than its production rate.
	let settings = rooms_application::admission::Settings::parse(
		|key| (key == "admission-rates").then(|| "create=512/512".into()),
		8192,
		1,
	)
	.unwrap();
	let running =
		super::super::start_with_admission(temp.0.clone(), tcp(), crate::server::Asked::default(), settings).await;
	let dial = glowcap::parse_locator(&running.location).unwrap();
	let total = MAX_ROWS + 4;
	let mut creators = Vec::new();
	let mut held = BTreeMap::new();
	for creator in 0..2 {
		let runtime = runtime().await;
		let client = Client::new(
			runtime.connect(&dial, ConnectOptions::default()).await.unwrap(),
			HostPlatform,
		);
		let directory = Directory::fetch(client.clone()).await.unwrap();
		for n in (creator..total).step_by(2) {
			let name = format!("Room-{n:03}");
			let entrance = directory.open(&name).await.unwrap();
			let (room, messages, _, _) = join(&client, entrance, "Keeper").await;
			held.insert(name, (room, messages));
		}
		creators.push((runtime, client, directory));
	}
	let opened: BTreeSet<_> = held.keys().cloned().collect();
	let (_, client, directory) = &creators[0];

	let first = directory.list(None).await.unwrap();
	assert_eq!(first.rooms.len(), MAX_ROWS);
	let cursor = first.next.clone().expect("more rooms than one page");
	// The last room of the first page closes before the second page is
	// asked for. An offset would skip the row after it; a position does not.
	let closing = first.rooms.last().unwrap().name.text().as_str().unwrap().to_owned();
	let (room, _messages) = held.remove(&closing).unwrap();
	room.leave().await.unwrap();
	let rest = directory.list(Some(&cursor)).await.unwrap();
	assert_eq!((rest.rooms.len(), &rest.next), (total - MAX_ROWS, &None));
	let mut listed = BTreeSet::new();
	for row in first.rooms.iter().chain(&rest.rooms) {
		assert!(
			listed.insert(row.name.text().as_str().unwrap().to_owned()),
			"listed twice"
		);
	}
	assert_eq!(listed, opened, "every room open for the whole walk is listed once");

	// Only a cursor the directory answered is a cursor.
	let refused = client
		.session()
		.send(directory.reference(), LIST, &["Room-000".into()])
		.await
		.unwrap_err();
	assert!(refused.to_string().contains("page cursor"), "{refused}");

	drop(held);
	for (runtime, _, _) in creators {
		closing_tolerated(runtime.close(PendingWork::Cancel).await);
	}
	running.stop.send(()).unwrap();
	running.task.await.unwrap().unwrap();
}
