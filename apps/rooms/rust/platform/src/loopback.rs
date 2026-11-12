//! A keyed TCP loopback for scenarios that need two real CapTP sessions.
use crate::HostPlatform;
use glowcap::{
	ConnectOptions, Host, ListenerIdentity, Locator, Runtime, RuntimeConfig, Session,
	tcp::{self, ListenOptions, Server},
};
use rooms_glowcap::client::Client;
use std::rc::Rc;
use tokio::task::JoinHandle;

/// A listener that proves `host`, a runtime that dials it, the accepted
/// session served on the local set, and a client over the dialed one. The
/// scenario closes `runtime`, `server`, and `host` and awaits `serving`.
pub struct Loopback {
	pub host: Host,
	pub server: Server,
	pub locator: Locator,
	pub runtime: Runtime,
	pub accepted: Rc<Session>,
	pub client: Client<HostPlatform>,
	pub serving: JoinHandle<glowcap::Result<()>>,
}

/// Opens a [`Loopback`] whose host identity derives from `seed`. Call it
/// inside a `LocalSet`, because the accepted session is served on it. Any
/// setup failure is returned, and the caller decides how a scenario ends.
pub async fn keyed_loopback(seed: [u8; 32]) -> glowcap::Result<Loopback> {
	let host = Host::from_seed(seed)?;
	let server = tcp::listen(
		"127.0.0.1",
		0,
		ListenOptions {
			identity: ListenerIdentity::Host(host.clone()),
			..Default::default()
		},
	)
	.await?;
	let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(tcp::Config {
		profiles: tcp::Profiles::TCP,
		..Default::default()
	})]))
	.await?;
	let locator = server.locator()?;
	let (connected, accepted) = tokio::join!(runtime.connect(&locator, ConnectOptions::default()), server.accept());
	let accepted = Rc::new(accepted?);
	let service = accepted.clone();
	let serving = tokio::task::spawn_local(async move { service.serve().await });
	let client = Client::new(connected?, HostPlatform);
	Ok(Loopback {
		host,
		server,
		locator,
		runtime,
		accepted,
		client,
		serving,
	})
}
