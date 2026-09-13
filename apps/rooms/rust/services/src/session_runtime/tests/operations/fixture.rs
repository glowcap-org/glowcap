//! One connected directory and durable checkpoint for acquisition races.
use super::*;
use rooms_runtime::directories::runtime::DirectoryRuntime;
pub(super) struct Fixture {
	_temp: Temp,
	pub(super) platform: ControlledPlatform,
	pub(super) commands: SessionCommands,
	command_task: tokio::task::JoinHandle<Result<(), rooms_runtime::Error>>,
	transport: Rc<Runtime>,
	pub(super) runtime: DirectoryRuntime<ControlledPlatform>,
	runtime_task: tokio::task::JoinHandle<Result<(), rooms_runtime::Error>>,
	peer: peers::Peer,
	pub(super) arrival: peers::Arrival,
	pub(super) arrivals: mpsc::Receiver<peers::Arrival>,
	pub(super) id: String,
	pub(super) operations: Operations<ControlledPlatform>,
}
impl Fixture {
	pub(super) async fn new(label: &str) -> Self {
		let platform = ControlledPlatform::default();
		let temp = Temp(std::env::temp_dir().join(format!("rooms-operations-{label}-{}", std::process::id())));
		std::fs::create_dir(&temp.0).unwrap();
		let docs = SessionDocuments::open(&temp.0).await.unwrap().into_owners();
		let (commands, command_worker) = SessionCommands::open(docs.state, rooms_platform::HostPlatform)
			.await
			.unwrap();
		let transport = Rc::new(
			Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
				.await
				.unwrap(),
		);
		let (runtime, worker, events, _inbox) = rooms_runtime::directories::runtime::DirectoryRuntime::new(
			transport.clone(),
			commands.clone(),
			"ocapn://member.id".into(),
			platform.clone(),
			rooms_platform::OsEntropy,
		)
		.unwrap();
		let command_task = tokio::task::spawn_local(command_worker.run(events));
		let runtime_task = tokio::task::spawn_local(worker.run());
		let (tx, mut arrivals) = mpsc::channel(2);
		let peer = peers::Peer::start(0, tx).await;
		let locator = peer.locator();
		let id = CheckpointRoutes.locator_authority(&locator).unwrap();
		let mut checkpoint: Value =
			serde_json::from_str(&Checkpoint::empty().encode_for(Access::Admin).unwrap()).unwrap();
		checkpoint["directories"] = json!([{"id":id,"locator":locator,"home":true,"nick":"alice","standing":null}]);
		commands
			.prepare_adoption(
				text("adopt"),
				0,
				Checkpoint::decode(&checkpoint.to_string(), &CheckpointRoutes).unwrap(),
			)
			.unwrap()
			.send()
			.unwrap()
			.wait()
			.await
			.unwrap();
		let arrival = arrivals.recv().await.unwrap();
		arrival.ack().await;
		command(
			&commands,
			"missing",
			Command::ReplaceOperationsCapabilities,
			vec![
				json!([{"capability":"listeners","scope":id,"swiss":"missing"}])
					.to_string()
					.into(),
			],
		)
		.await;
		let operations = Operations::new(platform.clone());
		let fixture = Self {
			_temp: temp,
			platform,
			commands,
			command_task,
			transport,
			runtime,
			runtime_task,
			peer,
			arrival,
			arrivals,
			id,
			operations,
		};
		fixture.connected().await;
		fixture
	}
	pub(super) async fn connected(&self) {
		let mut changes = self.runtime.changes();
		loop {
			changes.borrow_and_update();
			if self.runtime.read().rows()[0].phase() == Phase::Connected {
				return;
			}
			changes.changed().await.unwrap();
		}
	}
	pub(super) async fn close(self) {
		self.operations.stop();
		drop(self.operations);
		self.runtime.close().await.unwrap();
		self.runtime_task.await.unwrap().unwrap();
		self.commands.close().await.unwrap();
		self.command_task.await.unwrap().unwrap();
		self.peer.close().await;
		self.transport.close(PendingWork::Cancel).await.unwrap();
	}
}
