//! One-shot tasks client for the cross-language demo: connect, add a task,
//! list, mark it done, list again, and exit.
//!
//!   cargo run --bin tasks-client -- 127.0.0.1 9099 rs-linus "buy groceries"

mod board;

use std::time::Duration;

use board::Board;

async fn run_client(addr: &str, nick: &str, task_text: &str) -> Result<(), String> {
    let board = Board::join(addr).await?;

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
            eprintln!("{nick}: FAIL — task #{id} not marked completed");
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
    let addr = format!("{}:{}", args[1], args[2]);
    let nick = args[3].clone();
    let task_text = args[4].clone();

    let local = tokio::task::LocalSet::new();
    let result = local
        .run_until(async {
            match tokio::time::timeout(Duration::from_secs(15), run_client(&addr, &nick, &task_text)).await {
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
