//! A rooms chat client, written on pancake actors in native Rust.
//!
//! It joins the room, waits until it is full (learning the head count from the
//! room's own join announcements), posts one line, and collects every member's
//! line as the room pushes it back. All the OCapN machinery lives in `room.rs`
//! (`Room`), so this reads like a chat client — `while let Some(msg) =
//! room.recv().await` to receive, `room.say(line).await` to talk.
//!
//!   cargo run --bin rooms-client -- 127.0.0.1 9099 alice "hi" 3
//!
//! The last argument is how many members to expect; the client posts only once
//! that many have joined, so an all-to-all broadcast is deterministic regardless
//! of connect order. It exits 0 once it has seen a line from every member. This is
//! the same application as the Deno, Python, Racket, and Zig clients, on one wire.

mod room;

use std::time::Duration;

use room::Room;

/// The room announces each arrival as `<nick> joined (<count> here)`; pull the
/// head count back out so a client can wait for the room to fill.
fn roster_count(text: &str) -> Option<i64> {
    let open = text.find('(')?;
    let rest = &text[open + 1..];
    let end = rest.find(" here)")?;
    rest[..end].parse().ok()
}

async fn run_client(addr: &str, nick: &str, line: &str, expect: usize) -> Result<(), String> {
    let mut room = Room::join(addr, nick).await?;
    let mut present: i64 = 0;
    let mut posted = false;
    let mut chat = 0usize;

    while chat < expect {
        let message = match room.recv().await {
            Some(m) => m,
            None => break, // the room ended
        };
        println!("[{nick}] {}: {}", message.from, message.text);
        if message.system {
            if let Some(count) = roster_count(&message.text) {
                present = present.max(count);
            }
        } else {
            chat += 1;
        }
        // Post once the room is full, so every member is on the roster.
        if !posted && present >= expect as i64 {
            room.say(line).await;
            posted = true;
        }
    }
    room.leave().await;

    if chat < expect {
        return Err(format!("{nick} saw {chat}/{expect} chat lines before the room ended"));
    }
    Ok(())
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 5 {
        eprintln!("usage: rooms-client <host> <port> <nick> <line> [expectMembers]");
        std::process::exit(2);
    }
    let addr = format!("{}:{}", args[1], args[2]);
    let nick = args[3].clone();
    let line = args[4].clone();
    let expect: usize = args.get(5).and_then(|s| s.parse().ok()).unwrap_or(1);

    // The pancake peer is not `Send`, so the membership task is spawned local;
    // a `LocalSet` provides the context for it. A deadline keeps a stalled room
    // from hanging the process.
    let local = tokio::task::LocalSet::new();
    let result = local
        .run_until(async {
            match tokio::time::timeout(Duration::from_secs(15), run_client(&addr, &nick, &line, expect)).await {
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
