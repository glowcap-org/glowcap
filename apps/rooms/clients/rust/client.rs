//! A rooms chat client, written on glowcap actors in Rust.
//!
//! It enters the named room, waits until everyone it expects is present, posts
//! one line, and collects each expected member's line as the room pushes it
//! back. All the OCapN machinery lives in `room.rs` (`Room`), so this reads like
//! a chat client, `while let Some(msg) = room.recv().await` to receive,
//! `room.say(line).await?` to talk.
//!
//!   cargo run --bin rooms-client -- 127.0.0.1:9099 general alice "hi" alice,bob,carol
//!
//! The first argument is the locator: a `host:port` joins over TCP, an
//! `ocapn://<nodeid>.iroh?…` URI joins over iroh (with `--features iroh`). The
//! second is the room name (entering one that does not exist opens it).
//!
//! The last argument is the roster: a comma-separated list of the member nicks
//! to expect (default: just you). The client posts only once every roster member
//! is present, it learns who is present from the structured presence the room
//! attaches to each membership line (the roster on arrival and each join), and
//! exits 0 once it has seen a line from every roster member. Members outside the roster
//! (people already chatting in an attached room, say) are printed but never
//! counted, so a busy room cannot fake or break the assertion. This is the same
//! application as the Deno, Python, Racket, and Zig clients, on one wire.

/// The wire grammar every rooms client switches on, generated from
/// `tools/gen/rooms_protocol.zig` by `zig build gen-rooms-protocol`.
pub mod protocol_gen;
pub mod room;
/// This client's reading of the values a directory or room answers with, against
/// the generated grammar.
pub mod wire;

#[path = "../../../_demo/rust/run_local.rs"]
mod demo_run;
#[path = "../../../_demo/rooms_cli.rs"]
mod rooms_cli;

use std::collections::HashSet;

use protocol_gen::{Effect, SESSION_DEADLINE_MS};
use room::{Directory, Room};
use rooms_cli::{NO_SUCH_ROOM, ROOM_EXISTS, error_code};
use wire::RoomInfo;

/// The whole-roster deadline every sibling client holds, in seconds.
const SESSION_DEADLINE_S: u64 = SESSION_DEADLINE_MS / 1000;

/// Enter `name`, opening the room if it does not exist yet. status-allow: pending state or quoted runtime label
async fn enter_or_open(dir: &Directory, name: &str) -> Result<glowcap::Ref, String> {
	match dir.enter(name).await {
		Ok(room) => return Ok(room),
		Err(reason) if error_code(&reason) == NO_SUCH_ROOM => {}
		Err(reason) => return Err(reason),
	}
	match dir.open(name).await {
		Ok(room) => Ok(room),
		Err(reason) if error_code(&reason) == ROOM_EXISTS => dir.enter(name).await,
		Err(reason) => Err(reason),
	}
}

/// Render the live room list for one line of output.
fn format_rooms(rooms: &[RoomInfo]) -> String {
	if rooms.is_empty() {
		return "(none yet)".to_string();
	}
	rooms
		.iter()
		.map(|room| {
			format!(
				"{} ({})",
				room.name,
				room.count.map_or("unknown".to_string(), |count| count.to_string())
			)
		})
		.collect::<Vec<_>>()
		.join(", ")
}

/// The friendly entry the client uses: connect, show and follow discovery (the
/// first `list` page and the `watch` change feed), then enter the room (opening it
/// if new) and subscribe as `nick`.
async fn join_room(locator: &str, room_name: &str, nick: &str) -> Result<Room, String> {
	let dir = Directory::connect(locator).await?;
	let page = dir.list(None).await?;
	let more = if page.next.is_some() { " and more" } else { "" };
	println!("[{nick}] rooms: {}{more}", format_rooms(&page.rooms));
	let watch_nick = nick.to_string();
	dir.watch(move |kind, room| {
		let count = room.count.map_or("unknown".to_string(), |count| count.to_string());
		println!("[{watch_nick}] directory: {kind} {} ({count})", room.name);
	})
	.await?;
	let room_ref = enter_or_open(&dir, room_name).await?;
	Room::subscribe(dir.session(), room_ref, nick).await
}

async fn run_client(locator: &str, room_name: &str, nick: &str, line: &str, roster: &[String]) -> Result<(), String> {
	let mut room = join_room(locator, room_name, nick).await?;
	let mut present: HashSet<String> = HashSet::new();
	let mut seen: HashSet<String> = HashSet::new();
	let mut posted = false;

	while !roster.iter().all(|n| seen.contains(n)) {
		let message = match room.recv().await {
			Some(m) => m,
			None => break, // the room ended
		};
		println!("[{nick}] {}: {}", message.from, message.text);
		if let Some(presence) = &message.presence {
			// Membership arrives as structure. Only an arrival or a departure moves
			// a member in or out; the other tails are facts about a member who is
			// still here.
			match presence.effect {
				Effect::Depart => {
					for name in &presence.names {
						present.remove(name);
					}
				}
				Effect::Arrive => present.extend(presence.names.iter().cloned()),
				Effect::Stay => {}
			}
		} else if !message.system {
			present.insert(message.from.clone()); // a line is presence too
			if roster.contains(&message.from) {
				seen.insert(message.from.clone());
			}
		}
		// Post once every roster member is present, so each one receives it.
		if !posted && roster.iter().all(|n| present.contains(n)) {
			room.say(line).await?;
			posted = true;
		}
	}
	let ended = room.ended();
	room.leave().await?;

	if let Some(reason) = ended {
		return Err(format!("the room ended {nick}'s membership: {reason}"));
	}
	if !roster.iter().all(|n| seen.contains(n)) {
		let missing: Vec<&str> = roster
			.iter()
			.filter(|n| !seen.contains(*n))
			.map(String::as_str)
			.collect();
		return Err(format!(
			"{nick} saw lines from {}/{} members before the room ended (missing: {})",
			seen.len(),
			roster.len(),
			missing.join(", ")
		));
	}
	Ok(())
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
	let args: Vec<String> = std::env::args().collect();
	if args.len() < 5 {
		eprintln!(
			"usage: rooms-client <locator> <room> <nick> <line> [roster]   (locator: host:port or an ocapn://…iroh URI; roster: comma-separated nicks to expect; default just you)"
		);
		std::process::exit(2);
	}
	let locator = args[1].clone();
	let room_name = args[2].clone();
	let nick = args[3].clone();
	let line = args[4].clone();
	let roster: Vec<String> = match args.get(5) {
		Some(s) => s.split(',').filter(|n| !n.is_empty()).map(str::to_string).collect(),
		None => vec![nick.clone()],
	};

	let result = demo_run::run_with_timeout(
		&nick,
		SESSION_DEADLINE_S,
		run_client(&locator, &room_name, &nick, &line, &roster),
	)
	.await;
	demo_run::exit_on_result(&nick, "client", result);
}
