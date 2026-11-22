//! The Rooms bot, `rooms-bot control <json>`. See `rooms-bot/mod.rs`.
#[path = "../announce.rs"]
mod announce;
#[path = "rooms-bot/mod.rs"]
mod bot;

#[tokio::main(flavor = "current_thread")]
async fn main() {
	let args = std::env::args_os()
		.skip(1)
		.map(|arg| arg.into_string())
		.collect::<Result<Vec<_>, _>>();
	let result = match args {
		// glowcap's Runtime spawns local tasks, so the bot runs inside a LocalSet.
		Ok(args) => tokio::task::LocalSet::new().run_until(bot::run(args)).await,
		Err(_) => Err(bot::Error::Usage("bot options must be Unicode".into())),
	};
	if let Err(error) = result {
		println!("{}", bot::failure_line(&error));
		eprintln!("rooms bot: {error}");
		std::process::exit(1);
	}
}
