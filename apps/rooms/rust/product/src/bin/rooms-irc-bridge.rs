#[path = "../announce.rs"]
mod announce;
use rooms_services::irc_bridge::{self, Config};
use std::rc::Rc;

#[tokio::main(flavor = "current_thread")]
async fn main() {
	if let Err(error) = tokio::task::LocalSet::new().run_until(start()).await {
		eprintln!("rooms IRC bridge: {error}");
		std::process::exit(1);
	}
}
async fn start() -> Result<(), String> {
	let args = std::env::args_os()
		.skip(1)
		.map(|s| s.into_string().map_err(|_| "IRC bridge options must be Unicode".into()))
		.collect::<Result<Vec<_>, String>>()?;
	let Some(config) = Config::parse(args, |key| std::env::var(key).ok())? else {
		print!("{}", irc_bridge::HELP);
		return Ok(());
	};
	let mut interrupt =
		tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt()).map_err(|e| e.to_string())?;
	let mut terminate =
		tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).map_err(|e| e.to_string())?;
	irc_bridge::run(
		config,
		Rc::new(|notice| eprintln!("rooms IRC bridge: {notice}")),
		async move {
			tokio::select! {_=interrupt.recv()=>(), _=terminate.recv()=>()}
		},
		|ready| {
			announce::announce(&format!("ROOMS-IRC-BRIDGE-LISTENING {} {}", ready.port, ready.room));
		},
	)
	.await
}
