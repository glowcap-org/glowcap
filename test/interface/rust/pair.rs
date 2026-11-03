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
impl Pair {
	pub async fn open(host: &Host, options: HostOptions) -> Self {
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
		let client_host = Host::with_options(options).unwrap();
		let runtime =
			Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]).adopt_host(&client_host))
				.await
				.unwrap();
		let locator = server.locator().unwrap();
		let (client, accepted) = tokio::join!(runtime.connect(&locator, ConnectOptions::default()), server.accept());
		let client = Rc::new(client.unwrap());
		let negotiated = client.profile().unwrap();
		assert_eq!(negotiated.codec, options.codec);
		assert_eq!(negotiated.captp_version, options.captp_version);
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
