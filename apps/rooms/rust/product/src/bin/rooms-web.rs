use rooms_services::web::{self, Config};
use std::rc::Rc;
#[path = "../trace_output.rs"]
mod trace_output;

#[tokio::main(flavor = "current_thread")]
async fn main() {
	if let Err(error) = tokio::task::LocalSet::new().run_until(start()).await {
		eprintln!("rooms web: {error}");
		std::process::exit(1);
	}
}
async fn start() -> Result<(), String> {
	let args = std::env::args_os()
		.skip(1)
		.map(|s| s.into_string().map_err(|_| "web options must be Unicode".to_owned()))
		.collect::<Result<Vec<_>, _>>()?;
	if let Some(query) = web::StatusQuery::parse(&args, |key| std::env::var(key).ok())? {
		println!("{}", query.run().await?);
		return Ok(());
	}
	let mut interrupt =
		tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt()).map_err(|e| e.to_string())?;
	let mut terminate =
		tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).map_err(|e| e.to_string())?;
	if args.first().is_some_and(|arg| arg == "trace") {
		return rooms_services::trace_view::run(
			&args[1..],
			|key| std::env::var(key).ok(),
			async move {
				tokio::select! { _ = interrupt.recv() => (), _ = terminate.recv() => () }
			},
			trace_output::write,
		)
		.await;
	}
	if let Some(preparation) = web::Preparation::parse(&args)? {
		let prepared = preparation
			.run(async move {
				tokio::select! { _ = interrupt.recv() => (), _ = terminate.recv() => () }
			})
			.await?;
		if let Some(path) = prepared {
			println!("{}", path.display());
		}
		return Ok(());
	}
	let Some(config) = Config::parse(args, |key| std::env::var(key).ok())? else {
		print!("{}", web::HELP);
		return Ok(());
	};
	web::run(config, Rc::new(|notice| eprintln!("rooms web: {notice}")), async move {
		tokio::select! { _ = interrupt.recv() => (), _ = terminate.recv() => () }
	})
	.await
}
