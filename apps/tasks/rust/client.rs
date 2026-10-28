//! One-shot tasks client for the cross-language demo: join the board and watch
//! it, add a task, mark it done, print both lists, and exit 0 once the task
//! shows up under "Done" and the watcher saw the board change.
//!
//!   cargo run --bin tasks-client -- 127.0.0.1 9099 <board-name> rs-barbara "buy groceries"

mod board;
pub mod interface;

#[path = "../../_demo/rust/run_local.rs"]
mod demo_run;

use board::Board;
use glowcap::{Locator, tcp};

async fn run_client(locator: &Locator, name: &str, nick: &str, task_text: &str) -> Result<(), String> {
	let board = Board::join(locator, name).await?;
	let text = format!("[{nick}] {task_text}");

	let mut watcher = board.watch().await?;
	let task = board.add(&text).await?;
	println!("{nick}: added a task");
	board.done(&task).await?;
	println!("{nick}: marked it done");

	let lists = board.lists().await?;
	for list in &lists {
		println!("{nick}: {}: {} task(s)", list.name, list.tasks.len());
		for task in &list.tasks {
			println!("  {task}");
		}
	}
	let confirmed = lists.get(1).is_some_and(|done| done.tasks.contains(&text));
	let watched = watcher.changed().await?;
	watcher.stop().await?;
	board.leave().await?;
	if !confirmed {
		eprintln!("{nick}: FAIL, the task is not in the done list");
		return Err("the task is not in the done list".to_string());
	}
	println!("{nick}: confirmed the task is done");
	if !watched {
		eprintln!("{nick}: FAIL, the watcher saw no change");
		return Err("the watcher saw no change".to_string());
	}
	println!("{nick}: the watcher saw the board change");
	Ok(())
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
	let args: Vec<String> = std::env::args().collect();
	if args.len() < 6 {
		eprintln!("usage: tasks-client <host> <port> <board-name> <nick> <task-text>");
		std::process::exit(2);
	}
	let Ok(port) = args[2].parse::<u16>() else {
		eprintln!("usage: tasks-client <host> <port> <board-name> <nick> <task-text> (port must be a number)");
		std::process::exit(2);
	};
	let locator = tcp::locator(&args[1], port);
	let name = args[3].clone();
	let nick = args[4].clone();
	let task_text = args[5].clone();

	let result = demo_run::run_with_timeout(&nick, 15, run_client(&locator, &name, &nick, &task_text)).await;
	demo_run::exit_on_result(&nick, "client", result);
}
