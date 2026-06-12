//! A rooms chat client, written on pancake actors in native Rust.
//!
//! It joins the room, waits until everyone it expects is present, posts one
//! line, and collects each expected member's line as the room pushes it back.
//! All the OCapN machinery lives in `room.rs` (`Room`), so this reads like a
//! chat client — `while let Some(msg) = room.recv().await` to receive,
//! `room.say(line).await` to talk.
//!
//!   cargo run --bin rooms-client -- 127.0.0.1:9099 alice "hi" alice,bob,carol
//!
//! The first argument is the locator: a `host:port` joins over TCP, an
//! `ocapn://<nodeid>.iroh?…` URI joins over iroh (with `--features iroh`).
//!
//! The last argument is the roster: a comma-separated list of the member nicks
//! to expect (default: just you). The client posts only once every roster member
//! is present — it learns who is present from its welcome (which names everyone
//! already in the room) and from the room's join announcements — and exits 0
//! once it has seen a line from every roster member. Members outside the roster
//! (people already chatting in an attached room, say) are printed but never
//! counted, so a busy room cannot fake or break the assertion. This is the same
//! application as the Deno, Python, Racket, and Zig clients, on one wire.

mod room;

use std::collections::HashSet;
use std::time::Duration;

use room::Room;

/// The welcome ends with the nicks already present: `… in the room: a, b, c` —
/// the only way to learn about earlier arrivals.
fn welcome_names(text: &str) -> Option<Vec<String>> {
    let (_, names) = text.split_once(" in the room: ")?;
    Some(names.split(", ").map(str::to_string).collect())
}

/// The room announces each arrival as `<nick> joined (<count> here)`.
fn joined_nick(text: &str) -> Option<&str> {
    let idx = text.find(" joined (")?;
    if !text.ends_with(" here)") {
        return None;
    }
    Some(&text[..idx])
}

async fn run_client(locator: &str, nick: &str, line: &str, roster: &[String]) -> Result<(), String> {
    let mut room = Room::join(locator, nick).await?;
    let mut present: HashSet<String> = HashSet::new();
    let mut seen: HashSet<String> = HashSet::new();
    let mut posted = false;

    while !roster.iter().all(|n| seen.contains(n)) {
        let message = match room.recv().await {
            Some(m) => m,
            None => break, // the room ended
        };
        println!("[{nick}] {}: {}", message.from, message.text);
        if message.system {
            if let Some(names) = welcome_names(&message.text) {
                present.extend(names);
            }
            if let Some(name) = joined_nick(&message.text) {
                present.insert(name.to_string());
            }
        } else {
            present.insert(message.from.clone()); // a line is presence too
            if roster.contains(&message.from) {
                seen.insert(message.from.clone());
            }
        }
        // Post once every roster member is present, so each one receives it.
        if !posted && roster.iter().all(|n| present.contains(n)) {
            room.say(line).await;
            posted = true;
        }
    }
    room.leave().await;

    if !roster.iter().all(|n| seen.contains(n)) {
        let missing: Vec<&str> = roster.iter().filter(|n| !seen.contains(*n)).map(String::as_str).collect();
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
    if args.len() < 4 {
        eprintln!("usage: rooms-client <locator> <nick> <line> [roster]   (locator: host:port or an ocapn://…iroh URI; roster: comma-separated nicks to expect; default just you)");
        std::process::exit(2);
    }
    let locator = args[1].clone();
    let nick = args[2].clone();
    let line = args[3].clone();
    let roster: Vec<String> = match args.get(4) {
        Some(s) => s.split(',').filter(|n| !n.is_empty()).map(str::to_string).collect(),
        None => vec![nick.clone()],
    };

    // The pancake peer is not `Send`, so the membership task is spawned local;
    // a `LocalSet` provides the context for it. A deadline keeps a stalled room
    // from hanging the process.
    let local = tokio::task::LocalSet::new();
    let result = local
        .run_until(async {
            match tokio::time::timeout(Duration::from_secs(15), run_client(&locator, &nick, &line, &roster)).await {
                Ok(inner) => inner,
                Err(_) => Err(format!("{nick} timed out")),
            }
        })
        .await;

    match result {
        Ok(()) => std::process::exit(0),
        Err(err) => {
            eprintln!("client {nick} failed: {err}");
            std::process::exit(1);
        }
    }
}
