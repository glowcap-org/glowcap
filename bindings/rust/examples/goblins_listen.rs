//! Rust row of the live Goblins-listener matrix.

use glowcap_rust_dogfood::{tcp, Argument, PendingWork};

const ACTOR_SWISS: &str = "glowcapActorSwissnumABCDEFGH1234";

fn greeter(_verb: &str, args: &[Argument]) -> Result<Argument, String> {
	let who = match args.first() {
		Some(Argument::Bytes(value)) => String::from_utf8_lossy(value).into_owned(),
		Some(Argument::String(value)) => value.clone(),
		Some(value) => format!("{value:?}"),
		None => "stranger".into(),
	};
	Ok(Argument::String(format!("Hello from a binding host: {who}").into()))
}

async fn scene() -> Result<(), String> {
	let server = tcp::listen("127.0.0.1", 0, tcp::ListenOptions::default())
		.await
		.map_err(|error| error.to_string())?;
	server
		.host()
		.publish_giftable(ACTOR_SWISS, || Box::new(greeter))
		.map_err(|error| error.to_string())?;
	println!(
		"GOBLINS-LISTENER-READY {}",
		server.port().map_err(|error| error.to_string())?
	);

	let session = server.accept().await.map_err(|error| error.to_string())?;
	session.serve().await.map_err(|error| error.to_string())?;
	session
		.close(PendingWork::Cancel)
		.await
		.map_err(|error| error.to_string())?;
	server.close().await.map_err(|error| error.to_string())
}

fn main() {
	let runtime = tokio::runtime::Builder::new_current_thread()
		.enable_all()
		.build()
		.expect("runtime");
	let local = tokio::task::LocalSet::new();
	local.block_on(&runtime, async { scene().await.expect("Goblins listener") });
}
