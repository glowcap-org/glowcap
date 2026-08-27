//! An agent, written on pancake actors in native Rust. It connects to the tools
//! coordinator (which may be written in any language) and proves the three
//! capability properties — delegation, attenuation, revocation — over the wire.
//!
//!   cargo run --bin tools-agent -- 127.0.0.1 9099 rs-agent

#[path = "../../_demo/rust/run_local.rs"]
mod demo_run;
#[path = "../../_demo/rust/tools_check.rs"]
mod tools_check;

use pancake::{tcp, Argument, ConnectOptions, Locator, PendingWork, Ref, Runtime, RuntimeConfig};

fn cap(arg: &Argument) -> Result<Ref, String> {
	Ref::try_from(arg).map_err(|_| "grant did not return a capability".to_string())
}

async fn run(locator: &Locator, nick: &str) -> Result<(), String> {
	let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.map_err(|e| format!("runtime: {e:?}"))?;
	let session = runtime
		.connect(locator, ConnectOptions::default())
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

	let session_error = session.close(PendingWork::Cancel).await.err();
	let runtime_error = runtime.close(PendingWork::Cancel).await.err();
	let close_error = if session_error.is_some() || runtime_error.is_some() {
		Some(format!(
			"close failed{}{}",
			session_error.map_or_else(String::new, |error| format!("; session: {error}")),
			runtime_error.map_or_else(String::new, |error| format!("; runtime: {error}")),
		))
	} else {
		None
	};
	match (ok, close_error) {
		(true, None) => {
			println!("{nick}: all capability properties held");
			Ok(())
		}
		(true, Some(close)) => Err(close),
		(false, None) => Err("a capability property did not hold".to_string()),
		(false, Some(close)) => Err(format!("a capability property did not hold; {close}")),
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
	let locator = tcp::locator(&args[1], port);
	let nick = args[3].clone();

	let result = demo_run::run_with_timeout(&nick, 15, run(&locator, &nick)).await;
	demo_run::exit_on_result(&nick, "agent", result);
}
