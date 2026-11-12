#[path = "../announce.rs"]
mod announce;
use rooms_services::server::{self, Config, Error, Ready};
use std::{cell::Cell, rc::Rc};
#[tokio::main(flavor = "current_thread")]
async fn main() {
	let ready = Rc::new(Cell::new(false));
	let result = tokio::task::LocalSet::new().run_until(start(ready.clone())).await;
	if let Err(error) = result {
		let context = if ready.get() {
			"rooms server"
		} else {
			"rooms: could not start"
		};
		eprintln!("{context}: {error}");
		if let Error::Operations(_) = error
			&& let Ok(state) = std::env::var("GLOWCAP_ROOMS_STATE")
		{
			eprintln!(
				"rooms: {state}/operations.json holds operator-managed listener and IRC bridge choices. Repair it, or move it aside to start without those saved choices."
			);
		}
		std::process::exit(1);
	}
}
async fn start(started: Rc<Cell<bool>>) -> Result<(), Error> {
	let args = std::env::args_os()
		.skip(1)
		.map(|s| {
			s.into_string()
				.map_err(|_| Error::Refused("server options must be Unicode".into()))
		})
		.collect::<Result<Vec<_>, _>>()?;
	let Some(config) = Config::parse(args, |key| std::env::var(key).ok())? else {
		print!("{}", server::HELP);
		return Ok(());
	};
	let signal = |kind| {
		tokio::signal::unix::signal(kind)
			.map_err(|source| Error::Refused(format!("installing a signal handler failed: {source}").into()))
	};
	let mut interrupt = signal(tokio::signal::unix::SignalKind::interrupt())?;
	let mut terminate = signal(tokio::signal::unix::SignalKind::terminate())?;
	// A supervisor reads the JSON record, which carries the operator lines it
	// presents in its own block, so a supervised server prints nothing else.
	let supervised = std::env::var("GLOWCAP_ROOMS_SUPERVISED").as_deref() == Ok("1");
	let structured = match (std::env::var("GLOWCAP_ROOMS_READY_FORMAT").as_deref(), supervised) {
		(Err(std::env::VarError::NotPresent), supervised) => supervised,
		(Ok("json"), _) => true,
		(Ok("text"), false) => false,
		(Ok("text"), true) => {
			return Err(Error::Refused(
				"a supervised server reports readiness as JSON; GLOWCAP_ROOMS_READY_FORMAT=text contradicts GLOWCAP_ROOMS_SUPERVISED=1".into(),
			));
		}
		_ => return Err(Error::Refused("GLOWCAP_ROOMS_READY_FORMAT must be text or json".into())),
	};
	let transport = config.transport.describe();
	let keeps = config.history;
	let announced_host = config.transport.announces_host();
	let stop = async move {
		tokio::select! { _ = interrupt.recv() => (), _ = terminate.recv() => () }
	};
	let report = Rc::new(|notice| eprintln!("rooms server: {notice}"));
	server::run(
		config,
		stop,
		|ready: &Ready| -> Result<(), Error> {
			started.set(true);
			let location = ready.location.as_str();
			let token = rooms_platform::serving::announce_token(location, announced_host);
			// The announce line stays first and alone on stdout: its readers
			// wait for it. The human block rides behind it on stderr.
			if structured {
				announce::announce(ready.announcement(supervised));
			} else {
				announce::announce(&format!("ROOMS-SERVER-LISTENING {token}"));
			}
			if !supervised {
				eprint!("{}", boot_block(transport, location, keeps, &ready.lines));
			}
			Ok(())
		},
		report,
	)
	.await
}

/// The block a person reads when the server runs on its own: what is serving
/// where, each copyable value ending its own aligned line, then the
/// flush-left `ROOMS-*` lines to keep, and one ready line last.
fn boot_block(transport: &str, location: &str, keeps: bool, capabilities: &[String]) -> String {
	let mut lines: Vec<String> = Vec::new();
	lines.push("rooms: directory listening".into());
	lines.push(String::new());
	lines.push(format!("  transport   {transport}"));
	lines.push(format!("  locator     {location}"));
	if keeps {
		lines.push("  history     rooms keep their last lines".into());
	}
	if !capabilities.is_empty() {
		lines.push(String::new());
		lines.push(format!("  {}:", server::readiness::KEEP_LINKS_PRIVATE));
		lines.push(String::new());
		lines.extend(capabilities.iter().cloned());
	}
	lines.push(String::new());
	lines.push("rooms: ready".into());
	let mut block = lines.join("\n");
	block.push('\n');
	block
}
