//! One-shot tasks client for the cross-language demo: connect, add a task,
//! list, mark it done, list again, and exit.
//!
//!   cargo run --bin tasks-client -- 127.0.0.1 9099 rs-barbara "buy groceries"

mod board;

#[path = "../../_demo/rust/run_local.rs"]
mod demo_run;

use board::Board;
use pancake::tcp_locator;

async fn run_client(locator: &str, nick: &str, task_text: &str) -> Result<(), String> {
	let board = Board::join(locator).await?;

	let id = board.add(&format!("[{nick}] {task_text}")).await?;
	println!("{nick}: added task #{id}");

	let before = board.list().await?;
	println!("{nick}: {} task(s) on the board", before.len());
	for t in &before {
		let mark = if t.completed { "[x]" } else { "[ ]" };
		println!("  {mark} #{} {}", t.id, t.text);
	}

	board.done(id).await?;
	println!("{nick}: completed task #{id}");

	let after = board.list().await?;
	let ours = after.iter().find(|t| t.id == id);
	match ours {
		Some(t) if t.completed => println!("{nick}: confirmed task #{id} is done"),
		_ => {
			eprintln!("{nick}: FAIL, task #{id} not marked completed");
			board.leave().await;
			std::process::exit(1);
		}
	}

	board.leave().await;
	Ok(())
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
	let args: Vec<String> = std::env::args().collect();
	if args.len() < 5 {
		eprintln!("usage: tasks-client <host> <port> <nick> <task-text>");
		std::process::exit(2);
	}
	let Ok(port) = args[2].parse::<u16>() else {
		eprintln!("usage: tasks-client <host> <port> <nick> <task-text> (port must be a number)");
		std::process::exit(2);
	};
	let locator = tcp_locator(&args[1], port);
	let nick = args[3].clone();
	let task_text = args[4].clone();

	let result =
		demo_run::run_with_timeout(&nick, 15, run_client(&locator, &nick, &task_text)).await;
	demo_run::exit_on_result(&nick, "client", result);
}
