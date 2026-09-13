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
	if let Some(query) = server::CapabilityQuery::parse(&args, |key| std::env::var(key).ok())? {
		println!("{}", query.run().await?);
		return Ok(());
	}
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
	let structured = match std::env::var("GLOWCAP_ROOMS_READY_FORMAT").as_deref() {
		Err(std::env::VarError::NotPresent) | Ok("text") => false,
		Ok("json") => true,
		_ => return Err(Error::Refused("GLOWCAP_ROOMS_READY_FORMAT must be text or json".into())),
	};
	let transport = config.transport.describe();
	let keeps = config.history;
	// The announce token is what the harness and the web front read: a bare
	// port for a loopback TCP room, `host:port` for an announced one, and the
	// complete locator for every other transport.
	let announced_host = matches!(&config.transport, server::Transport::Tcp { announce: Some(_), .. });
	let stop = async move {
		tokio::select! { _ = interrupt.recv() => (), _ = terminate.recv() => () }
	};
	let report = Rc::new(|notice| eprintln!("rooms server: {notice}"));
	server::run(
		config,
		stop,
		|ready: &Ready| {
			started.set(true);
			let location = ready.location.as_str();
			let token = match glowcap::parse_locator(location) {
				Ok(locator) if locator.transport == glowcap::TRANSPORT_TCP && !announced_host => locator
					.designator
					.rsplit_once(':')
					.map(|(_, port)| port.to_owned())
					.unwrap_or(locator.designator),
				Ok(locator) if locator.transport == glowcap::TRANSPORT_TCP => locator.designator,
				_ => location.to_owned(),
			};
			// The announce line stays first and alone on stdout: its readers
			// wait for it. The human block rides behind it on stderr.
			if structured {
				println!("{}", ready.announcement());
			} else {
				println!("ROOMS-SERVER-LISTENING {token}");
			}
			if let Some(trace) = &ready.trace {
				eprintln!("ROOMS-TRACE-LISTENING {trace}");
			}
			eprint!("{}", boot_block(transport, location, keeps, &ready.capabilities));
		},
		report,
	)
	.await
}

/// The block a person reads. Under a supervisor, which owns the presentation
/// and prints its own serving block, only the flush-left `ROOMS-*` token
/// lines print: they are the grep contract of the flags that minted them.
/// Standalone, this block is the presentation: what is serving where, each
/// copyable value ending its own aligned line, and one ready line last.
fn boot_block(transport: &str, location: &str, keeps: bool, capabilities: &[server::Minted]) -> String {
	let mut lines: Vec<String> = Vec::new();
	if std::env::var("GLOWCAP_ROOMS_SUPERVISED").as_deref() == Ok("1") {
		lines.extend(capabilities.iter().map(server::Minted::line));
	} else {
		lines.push("rooms: directory listening".into());
		lines.push(String::new());
		lines.push(format!("  transport   {transport}"));
		lines.push(format!("  locator     {location}"));
		if keeps {
			lines.push("  history     listed rooms keep their last lines".into());
		}
		if !capabilities.is_empty() {
			lines.push(String::new());
			lines.push("  operator capabilities, fetch each by its swiss:".into());
			lines.push(String::new());
			lines.extend(capabilities.iter().map(server::Minted::line));
		}
		lines.push(String::new());
		lines.push("rooms: ready".into());
	}
	let mut block = lines.join("\n");
	if !block.is_empty() {
		block.push('\n');
	}
	block
}
