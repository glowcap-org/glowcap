use rooms_services::archive::peer::{self, Config};
use std::rc::Rc;
#[tokio::main(flavor = "current_thread")]
async fn main() {
	let result = tokio::task::LocalSet::new().run_until(start()).await;
	if let Err(error) = result {
		eprintln!("rooms archive: {error}");
		std::process::exit(1);
	}
}
async fn start() -> Result<(), String> {
	let args = std::env::args_os()
		.skip(1)
		.map(|s| {
			s.into_string()
				.map_err(|_| "archive options must be Unicode".to_string())
		})
		.collect::<Result<Vec<_>, _>>()?;
	let Some(config) = Config::parse(args, |key| std::env::var(key).ok())? else {
		print!("{}", peer::HELP);
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
	let report = Rc::new(|notice| eprintln!("rooms archive: {notice}"));
	peer::run(
		config,
		stop,
		|link| {
			println!("ROOMS-ARCHIVE-LISTENING {link}");
			eprintln!("rooms archive: host peer ready over {transport}; the sturdyref is the archive authority");
		},
		report,
	)
	.await
}
