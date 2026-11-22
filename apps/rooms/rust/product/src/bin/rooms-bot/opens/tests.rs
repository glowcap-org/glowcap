//! Kept opens settle through the stand-in session: each settled answer drops
//! its open, an unsettled one is looked at again across restarts until its
//! last look, and a replaced link's last look gives up what it cannot settle.
#![cfg(feature = "test-support")]
use super::*;
use crate::bot::rooms::files::Files;
use rooms_testing::scratch::Scratch;

const OPERATIONS: [&str; 4] = [
	"0000000000000000000000000000000a",
	"0000000000000000000000000000000b",
	"0000000000000000000000000000000c",
	"0000000000000000000000000000000d",
];

fn plant(store: &Store, operation: &str) {
	let open = Open {
		base: Base(3),
		introduction: Introduction {
			directory: "d".into(),
			peer: "ann".into(),
			registration: "r".into(),
		},
		looks: 0,
	};
	store.write_in(DIRECTORY, &format!("{operation}.json"), &open).unwrap();
}

fn answer(rooms: &Path, answers: &str) {
	std::fs::write(rooms.join("open-answers"), answers).unwrap();
}

fn kept(store: &Store) -> Vec<(String, u32)> {
	let mut kept: Vec<_> = std::fs::read_dir(store.root().join(DIRECTORY))
		.unwrap()
		.map(|entry| {
			let name = entry.unwrap().file_name().into_string().unwrap();
			let open: Open = store.read_in(DIRECTORY, &name).unwrap().unwrap();
			(name.trim_end_matches(".json").to_owned(), open.looks)
		})
		.collect();
	kept.sort();
	kept
}

#[tokio::test]
async fn a_settled_answer_drops_its_open_and_an_unsettled_one_is_looked_at_until_its_last_look() {
	let scratch = Scratch::create("bot-opens");
	let (bot, session) = (scratch.join("bot"), scratch.join("session"));
	std::fs::create_dir_all(&session).unwrap();
	let rooms = Files::open(&session);
	let store = Store::open(&bot).unwrap();
	assert_eq!(look(&rooms, &store, false).await.unwrap(), 0, "nothing is kept");
	for operation in &OPERATIONS[..3] {
		plant(&store, operation);
	}
	answer(&session, "opened\nuncertain\nrefused\n");
	assert_eq!(look(&rooms, &store, false).await.unwrap(), 0);
	assert_eq!(kept(&store), [(OPERATIONS[1].into(), 1), (OPERATIONS[2].into(), 1)]);
	drop(store);
	let store = Store::open(&bot).unwrap();
	answer(&session, "paused\nunreachable\n");
	assert_eq!(look(&rooms, &store, false).await.unwrap(), 0);
	assert_eq!(
		kept(&store),
		[(OPERATIONS[1].into(), 1), (OPERATIONS[2].into(), 1)],
		"a paused or unreachable look counts nothing"
	);
	answer(&session, "reused\nuncertain\n");
	assert_eq!(look(&rooms, &store, false).await.unwrap(), 0);
	assert_eq!(kept(&store), [(OPERATIONS[2].into(), 2)]);
	for looks in 3..MAX_LOOKS {
		answer(&session, "uncertain\n");
		assert_eq!(look(&rooms, &store, false).await.unwrap(), 0);
		assert_eq!(kept(&store), [(OPERATIONS[2].into(), looks)]);
	}
	answer(&session, "uncertain\n");
	assert_eq!(look(&rooms, &store, false).await.unwrap(), 1, "the last look gives up");
	assert!(kept(&store).is_empty());
	let log = std::fs::read_to_string(bot.join("bot.log")).unwrap();
	assert!(log.contains("the bot stops looking"), "{log}");
}

#[tokio::test]
async fn a_revoked_access_settles_its_opens_and_a_last_look_gives_up_the_rest() {
	let scratch = Scratch::create("bot-opens-last");
	let (bot, session) = (scratch.join("bot"), scratch.join("session"));
	std::fs::create_dir_all(&session).unwrap();
	let rooms = Files::open(&session);
	let store = Store::open(&bot).unwrap();
	for operation in OPERATIONS {
		plant(&store, operation);
	}
	answer(&session, "revoked\nunapplied\nreleased\nunreachable\n");
	assert_eq!(
		look(&rooms, &store, true).await.unwrap(),
		1,
		"only the unreachable one is lost"
	);
	assert!(kept(&store).is_empty());
}
