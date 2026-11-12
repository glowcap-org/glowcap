//! An agent, written on glowcap actors in native Rust. It connects to the tools
//! coordinator (which may be written in any language) and proves the three
//! capability properties — delegation, attenuation, revocation — over the wire.
//!
//!   cargo run --bin tools-agent -- <locator> rs-agent
//!
//! The locator is the `ocapn://` URI the coordinator printed.

#[path = "../../_demo/rust/run_local.rs"]
mod demo_run;
#[path = "../../_demo/rust/tools_check.rs"]
mod tools_check;

use glowcap::{Argument, ConnectOptions, ErrorKind, Locator, PendingWork, Ref, Runtime, RuntimeConfig, tcp};

/// Whether the partner broke the call. Only a broken promise is the refusal
/// these checks look for, so a transport or marshalling failure is returned
/// with its own cause.
fn broke(outcome: glowcap::Result<Argument>, what: &str) -> Result<bool, String> {
	match outcome {
		Ok(_) => Ok(false),
		Err(err) if err.kind() == ErrorKind::Broken => Ok(true),
		Err(err) => Err(format!("{what}: {err}")),
	}
}

fn cap(arg: &Argument) -> Result<Ref, String> {
	Ref::try_from(arg).map_err(|_| "grant did not return a capability".to_string())
}

async fn run(locator: &Locator, nick: &str) -> Result<(), String> {
	let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(tcp::Config {
		profiles: tcp::Profiles::NOISE_TCP,
		..Default::default()
	})]))
	.await
	.map_err(|e| format!("runtime: {e}"))?;
	let session = runtime
		.connect(locator, ConnectOptions::default())
		.await
		.map_err(|e| format!("connect: {e}"))?;
	let tools = session.fetch("tools").await.map_err(|e| format!("fetch tools: {e}"))?;
	let mut ok = true;

	let clock = cap(&session
		.send(&tools, "grant", &["clock".into()])
		.await
		.map_err(|e| format!("grant clock: {e}"))?)?;
	let now = session.send(&clock, "now", &[]).await;
	ok &= tools_check::check(
		nick,
		"delegation: was handed a clock and called it",
		matches!(now, Ok(Argument::Integer(_))),
	);

	let files = cap(&session
		.send(&tools, "grant", &["files-readonly".into()])
		.await
		.map_err(|e| format!("grant files: {e}"))?)?;
	let read = session.send(&files, "read", &["report.txt".into()]).await;
	ok &= tools_check::check(
		nick,
		"attenuation: read through the read-only view",
		matches!(read, Ok(Argument::String(_))),
	);
	let write = session
		.send(&files, "write", &["report.txt".into(), "tampered".into()])
		.await;
	ok &= tools_check::check(nick, "attenuation: write is refused", broke(write, "write")?);

	let revocable = cap(&session
		.send(&tools, "grant-revocable", &["clock".into()])
		.await
		.map_err(|e| format!("grant-revocable: {e}"))?)?;
	ok &= tools_check::check(
		nick,
		"revocation: the handle works before revoke",
		session.send(&revocable, "now", &[]).await.is_ok(),
	);
	session
		.send(&tools, "revoke-last", &[])
		.await
		.map_err(|e| format!("revoke-last: {e}"))?;
	ok &= tools_check::check(
		nick,
		"revocation: the handle breaks after revoke",
		broke(session.send(&revocable, "now", &[]).await, "now after revoke")?,
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
	if args.len() < 3 {
		eprintln!("usage: tools-agent <locator> <nick>");
		std::process::exit(2);
	}
	let locator = match glowcap::parse_locator(&args[1]) {
		Ok(locator) => locator,
		Err(err) => {
			eprintln!("usage: tools-agent <locator> <nick> ({err})");
			std::process::exit(2);
		}
	};
	let nick = args[2].clone();

	let result = demo_run::run_with_timeout(&nick, 15, run(&locator, &nick)).await;
	demo_run::exit_on_result(&nick, "agent", result);
}
