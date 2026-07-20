//! An agent, written on pancake actors in native Rust. It connects to the tools
//! coordinator (which may be written in any language) and proves the three
//! capability properties — delegation, attenuation, revocation — over the wire.
//!
//!   cargo run --bin tools-agent -- 127.0.0.1 9099 rs-agent

#[path = "../../_demo/rust/run_local.rs"]
mod demo_run;
#[path = "../../_demo/rust/tools_check.rs"]
mod tools_check;

use pancake::{connect, tcp_locator, Argument, Ref};

fn cap(arg: &Argument) -> Result<Ref, String> {
	Ref::try_from(arg).map_err(|_| "grant did not return a capability".to_string())
}

async fn run(locator: &str, nick: &str) -> Result<(), String> {
	let session = connect(locator, None, None)
		.await
		.map_err(|e| format!("connect: {e:?}"))?;
	let tools = session
		.fetch("tools")
		.await
		.map_err(|e| format!("fetch tools: {e:?}"))?;
	let mut ok = true;

	let clock = cap(&session
		.send(&tools, "grant", &["clock".into()])
		.await
		.map_err(|e| format!("grant clock: {e:?}"))?)?;
	let now = session.send(&clock, "now", &[]).await;
	ok &= tools_check::check(
		nick,
		"delegation: was handed a clock and called it",
		matches!(now, Ok(Argument::Integer(_))),
	);

	let files = cap(&session
		.send(&tools, "grant", &["files-readonly".into()])
		.await
		.map_err(|e| format!("grant files: {e:?}"))?)?;
	let read = session.send(&files, "read", &["report.txt".into()]).await;
	ok &= tools_check::check(
		nick,
		"attenuation: read through the read-only view",
		matches!(read, Ok(Argument::String(_))),
	);
	let write = session
		.send(&files, "write", &["report.txt".into(), "tampered".into()])
		.await;
	ok &= tools_check::check(nick, "attenuation: write is refused", write.is_err());

	let revocable = cap(&session
		.send(&tools, "grant-revocable", &["clock".into()])
		.await
		.map_err(|e| format!("grant-revocable: {e:?}"))?)?;
	ok &= tools_check::check(
		nick,
		"revocation: the handle works before revoke",
		session.send(&revocable, "now", &[]).await.is_ok(),
	);
	session
		.send(&tools, "revoke-last", &[])
		.await
		.map_err(|e| format!("revoke-last: {e:?}"))?;
	ok &= tools_check::check(
		nick,
		"revocation: the handle breaks after revoke",
		session.send(&revocable, "now", &[]).await.is_err(),
	);

	session.close();
	if ok {
		println!("{nick}: all capability properties held");
		Ok(())
	} else {
		Err("a capability property did not hold".to_string())
	}
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
	let args: Vec<String> = std::env::args().collect();
	if args.len() < 4 {
		eprintln!("usage: tools-agent <host> <port> <nick>");
		std::process::exit(2);
	}
	let Ok(port) = args[2].parse::<u16>() else {
		eprintln!("usage: tools-agent <host> <port> <nick> (port must be a number)");
		std::process::exit(2);
	};
	let locator = tcp_locator(&args[1], port);
	let nick = args[3].clone();

	let result = demo_run::run_with_timeout(&nick, 15, run(&locator, &nick)).await;
	demo_run::exit_on_result(&nick, "agent", result);
}
