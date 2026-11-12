//! One live TCP pair for independently authored interface behaviors.
use glowcap::{ConnectOptions, Host, HostOptions, ListenerIdentity, PendingWork, Runtime, RuntimeConfig, Session, tcp};
use std::rc::Rc;

pub struct Pair {
	pub client: Rc<Session>,
	pub accepted: Session,
	server: tcp::Server,
	runtime: Runtime,
	serving: tokio::task::JoinHandle<glowcap::Result<()>>,
}
/// Cleartext `tcp`, because a proxy fixture reads the frames on the wire.
fn plain_tcp() -> tcp::Config {
	tcp::Config {
		profiles: tcp::Profiles::TCP,
		..Default::default()
	}
}

impl Pair {
	pub async fn open(host: &Host, options: HostOptions) -> Self {
		let client_host = Host::with_options(options).unwrap();
		let pair = Self::open_with_client(host, &client_host).await;
		let negotiated = pair.client.profile().unwrap();
		assert_eq!(negotiated.codec, options.codec);
		assert_eq!(negotiated.captp_version, options.captp_version);
		pair
	}
	/// Both peers keep their configured Host allocation policy. The pair owns
	/// the accepted Session until serving and the close barrier have completed.
	pub async fn open_with_client(host: &Host, client_host: &Host) -> Self {
		Self::open_routed(host, client_host, |locator| locator).await
	}
	/// A diagnostic may route TCP through a byte-preserving observer. The
	/// ordinary pair has no routing callback after construction.
	pub async fn open_routed(
		host: &Host,
		client_host: &Host,
		route: impl FnOnce(glowcap::Locator) -> glowcap::Locator,
	) -> Self {
		let server = tcp::listen(
			"127.0.0.1",
			0,
			tcp::ListenOptions {
				identity: ListenerIdentity::Host(host.clone()),
				..Default::default()
			},
		)
		.await
		.unwrap();
		let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(plain_tcp())]).adopt_host(client_host))
			.await
			.unwrap();
		let locator = route(server.locator().unwrap());
		let (client, accepted) = tokio::join!(runtime.connect(&locator, ConnectOptions::default()), server.accept());
		let client = Rc::new(client.unwrap());
		let accepted = accepted.unwrap();
		let serving = tokio::task::spawn_local(accepted.serve());
		Self {
			client,
			accepted,
			server,
			runtime,
			serving,
		}
	}
	pub async fn close(self) {
		self.client.close(PendingWork::Cancel).await.unwrap();
		self.server.close().await.unwrap();
		self.runtime.close(PendingWork::Cancel).await.unwrap();
		self.server.host().close(PendingWork::Cancel).await.unwrap();
		self.serving.await.unwrap().unwrap();
	}
}
