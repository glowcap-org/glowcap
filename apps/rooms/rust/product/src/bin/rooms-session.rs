//! The host durable Rooms session peer. Options come from the command line
//! or `GLOWCAP_ROOMS_SESSION_*`; the one stdout line announces the
//! workspace use sturdyref, and everything else goes to stderr.
//!
//! `--check-ready=<path>` is the deployment's healthcheck: it reads the
//! readiness mirror a running peer wrote, prints the sturdyref when the file
//! holds exactly one, and exits nonzero otherwise, so the container needs no
//! second runtime to ask whether the peer is up.
use rooms_services::session::{self, Config, Notice};
use std::rc::Rc;
#[path = "rooms-session/commands/mod.rs"]
mod commands;

/// A readiness mirror holds one sturdyref and a newline; anything larger is
/// debris, not a longer link.
const MAX_READINESS_BYTES: u64 = 2_048;

#[tokio::main(flavor = "current_thread")]
async fn main() {
	let result = tokio::task::LocalSet::new().run_until(start()).await;
	if let Err(error) = result {
		eprintln!("rooms session: {error}");
		std::process::exit(1);
	}
}

async fn start() -> Result<(), String> {
	let mut args = std::env::args_os()
		.skip(1)
		.map(|s| {
			s.into_string()
				.map_err(|_| "session options must be Unicode".to_string())
		})
		.collect::<Result<Vec<_>, _>>()?;
	if args.first().map(String::as_str) == Some("control") {
		let [_, body] = args.as_slice() else {
			return Err("use glowcap apps rooms session for Rooms commands".into());
		};
		return commands::run(body).await;
	}
	if let [only] = args.as_slice()
		&& let Some(path) = only.strip_prefix("--check-ready=")
	{
		return check_ready(path);
	}
	let control = args.iter().filter(|arg| *arg == "--local-control").count();
	if control > 1 {
		return Err("repeated --local-control".into());
	}
	args.retain(|arg| arg != "--local-control");
	let Some(config) = Config::parse(args, |key| std::env::var(key).ok()).map_err(|e| e.to_string())? else {
		print!("{}", session::HELP);
		return Ok(());
	};
	let mut interrupt =
		tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt()).map_err(|e| e.to_string())?;
	let mut terminate =
		tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).map_err(|e| e.to_string())?;
	let transport = config.transport.describe();
	let stop = async move {
		tokio::select! { _ = interrupt.recv() => (), _ = terminate.recv() => () }
	};
	let report = Rc::new(|notice: Notice| eprintln!("rooms session: {notice}"));
	if control == 1 {
		let mut peer = session::Peer::open(config, report).await.map_err(|e| e.to_string())?;
		let mut control =
			match session::control::Control::open(&peer, Rc::new(|error| eprintln!("Rooms local control: {error}")))
				.await
			{
				Ok(control) => control,
				Err(error) => {
					while let Err(cleanup) = peer.close().await {
						eprintln!("Rooms session startup close: {cleanup}");
						tokio::time::sleep(std::time::Duration::from_secs(1)).await;
					}
					return Err(error.to_string());
				}
			};
		println!("ROOMS-SESSION-LISTENING {}", peer.link());
		let served = peer.serve(control.serve(stop)).await;
		// A transport can end serving before the halt future resolves. Both
		// exits drain local commands while the peer still owns a running Host.
		while let Err(error) = control.drain().await {
			eprintln!("Rooms local control drain: {error}");
			tokio::time::sleep(std::time::Duration::from_secs(1)).await;
		}
		loop {
			match peer.close().await {
				Ok(()) => break,
				Err(error) => {
					eprintln!("Rooms session close: {error}");
					tokio::time::sleep(std::time::Duration::from_secs(1)).await;
				}
			}
		}
		// Socket absence is the command front's completed-stop witness. Keep it
		// until the managed store has released its state-directory lease.
		while let Err(error) = control.close().await {
			eprintln!("Rooms local control close: {error}");
			tokio::time::sleep(std::time::Duration::from_secs(1)).await;
		}
		return served.map_err(|error| error.to_string());
	}
	session::run(
		config,
		stop,
		|link| {
			println!("ROOMS-SESSION-LISTENING {link}");
			eprintln!("rooms session: host peer ready over {transport}; management is in control.sturdyref");
		},
		report,
	)
	.await
	.map_err(|e| e.to_string())
}

fn check_ready(path: &str) -> Result<(), String> {
	use std::io::Read;
	let not_ready = |reason: String| format!("not ready: {reason}");
	let file = std::fs::File::open(path).map_err(|e| not_ready(e.to_string()))?;
	let mut document = String::new();
	file.take(MAX_READINESS_BYTES + 1)
		.read_to_string(&mut document)
		.map_err(|e| not_ready(e.to_string()))?;
	if document.len() as u64 > MAX_READINESS_BYTES {
		return Err(not_ready("the readiness file is larger than one sturdyref".into()));
	}
	let link = document.trim_end_matches('\n');
	if link.is_empty() || link.contains('\n') || link.trim() != link {
		return Err(not_ready("the readiness file is not one sturdyref".into()));
	}
	glowcap::parse_sturdyref(link, glowcap::CaptpVersion::V1_0).map_err(|e| not_ready(e.to_string()))?;
	println!("{link}");
	Ok(())
}
