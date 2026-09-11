//! The complete native session composition also runs in Wasm. Transport and
//! documents are fixtures; visualization deliberately has no publisher here.
use glowcap::{Argument, CaptpVersion, Host, Locator, PendingWork, Runtime, RuntimeConfig, Session};
use rooms_application::{
	documents::SessionDocument,
	session::{checkpoint::commands::Command, state::OperationId},
};
use rooms_browser::platform::Platform;
use rooms_glowcap::client::{
	session::{Event, Observer, Session as Attached},
	Client,
};
use rooms_runtime::{
	documents::{VolatileDocument, VolatileDocuments},
	entropy::{Entropy, EntropyUnavailable},
	grants::DurableGrants,
	session_commands::{SessionCommands, SessionWorker},
	session_service::{error::Error, Inputs, Session as Application, Visualization},
	session_state::DurableSession,
};
use std::{cell::Cell, rc::Rc};
use tokio::sync::watch;

// Deterministic private material belongs only to this restoration fixture.
struct SeedEntropy;
impl Entropy for SeedEntropy {
	fn fill(&mut self, bytes: &mut [u8]) -> Result<(), EntropyUnavailable> {
		bytes.fill(0x63);
		Ok(())
	}
}
struct NoEntropy;
impl Entropy for NoEntropy {
	fn fill(&mut self, _: &mut [u8]) -> Result<(), EntropyUnavailable> {
		Err(EntropyUnavailable)
	}
}
async fn state(platform: Platform) -> (SessionCommands, SessionWorker<VolatileDocuments, SeedEntropy, Platform>) {
	SessionCommands::open(DurableSession::new(VolatileDocuments::default(), SeedEntropy), platform)
		.await
		.unwrap()
}
fn inputs<F>(platform: Platform, runtime: Rc<Runtime>, locator: &Locator, entropy: F) -> Inputs<Platform, F> {
	Inputs {
		recording_source: None,
		connections: rooms_runtime::connections::Connections::new(runtime, platform.clone()),
		platform,
		locator: locator.clone(),
		entropy,
		viz: Rc::new(FixtureViz(watch::channel(()).0)),
		report: Rc::new(|notice| panic!("session notice: {notice:?}")),
	}
}
fn grants() -> DurableGrants<VolatileDocument> {
	DurableGrants::new(VolatileDocument::new(SessionDocument::Grants))
}
struct FixtureViz(watch::Sender<()>);
struct Views {
	changed: Rc<Cell<u64>>,
	retired: Rc<Cell<bool>>,
}
impl Drop for Views {
	fn drop(&mut self) {
		self.retired.set(true);
	}
}
impl Observer for Views {
	fn changed(&mut self, snapshot: rooms_application::session::snapshot::Snapshot) -> Result<(), String> {
		self.changed.set(snapshot.revision.get());
		Ok(())
	}
	fn event(&mut self, _: Event<glowcap::Ref>) -> Result<(), String> {
		Ok(())
	}
	fn history_changed(&mut self, _: rooms_application::archive::change::Change) -> Result<(), String> {
		Ok(())
	}
	fn operations_changed(&mut self, _: &str) -> Result<(), String> {
		Ok(())
	}
}
impl Visualization for FixtureViz {
	fn on_invalidated(&self, _: Rc<dyn Fn(&str)>) {}
	fn stop(&self) {}
	fn close(&self) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<(), Error>> + '_>> {
		Box::pin(async { Ok(()) })
	}
	fn kick(&self) {
		self.0.send_replace(());
	}
	fn changes(&self) -> watch::Receiver<()> {
		self.0.subscribe()
	}
	fn snapshot(&self, _: &str, _: &SessionCommands) -> Result<Argument, Error> {
		Err(Error::refused("fixture has no visualization transport"))
	}
	fn reconcile(&self, _: &SessionCommands) {}
}

pub async fn exercise(platform: Platform) {
	let prepared = state(platform.clone()).await;
	let seed = prepared.0.view().read(|s| *s.identity_seed().unwrap()).unwrap();
	let host = Host::from_seed_with_options(seed, rooms_glowcap::host_options()).unwrap();
	let runtime = Rc::new(
		Runtime::open(RuntimeConfig::connectors([]).adopt_host(&host))
			.await
			.unwrap(),
	);
	let locator = Locator::bare("tcp", "127.0.0.1:9001");
	// Early failure must retire the already-started archive worker, including
	// when no room/command worker has been polled yet.
	let failed = Application::open(
		inputs(platform.clone(), runtime.clone(), &locator, || NoEntropy),
		prepared,
		grants(),
		VolatileDocument::new(SessionDocument::BridgeSecrets),
		super::browser_archive::Memory::new(),
		None,
	)
	.await
	.err()
	.expect("entropy must refuse");
	assert!(failed.to_string().contains("entropy"));

	let caller = Host::with_options(rooms_glowcap::host_options()).unwrap();
	let (left, right) = tokio::io::duplex(4096);
	let (dialed, accepted) = tokio::join!(
		Session::dial_over(&caller, &locator, left, None),
		Session::accept_over(&host, "tcp", "127.0.0.1:9001", "127.0.0.1:9001", right, None)
	);
	let accepted = accepted.unwrap();
	let client = Client::new(dialed.unwrap(), platform.clone());
	let session = client.session();
	// A collision must preserve someone else's publication while retiring
	// every worker and grant owner this failed startup created.
	let foreign = host
		.publish_durable_with_entropy([0x63; 16], || Box::new(|_, _| Ok("foreign".into())))
		.unwrap();
	let failed = Application::open(
		inputs(platform.clone(), runtime.clone(), &locator, || platform.clone()),
		state(platform.clone()).await,
		grants(),
		VolatileDocument::new(SessionDocument::BridgeSecrets),
		super::browser_archive::Memory::new(),
		None,
	)
	.await;
	assert!(failed.is_err());
	let held_foreign = session.fetch(&foreign).await.unwrap();
	assert_eq!(
		session.send(&held_foreign, "still-owned", &[]).await.unwrap().as_str(),
		Some("foreign")
	);
	host.remove_durable(&foreign).unwrap();

	let mut prior_link = None;
	for restart in 0..2 {
		let prepared = state(platform.clone()).await;
		let commands = prepared.0.clone();
		let application = Application::open(
			inputs(platform.clone(), runtime.clone(), &locator, || platform.clone()),
			prepared,
			grants(),
			VolatileDocument::new(SessionDocument::BridgeSecrets),
			super::browser_archive::Memory::new(),
			None,
		)
		.await
		.unwrap();
		if let Some(prior) = &prior_link {
			assert_eq!(application.link().expect("fixture session published at open"), prior);
		}
		prior_link = Some(
			application
				.link()
				.expect("fixture session published at open")
				.to_owned(),
		);
		let parsed = glowcap::parse_sturdyref(
			application.link().expect("fixture session published at open"),
			CaptpVersion::V1_0,
		)
		.unwrap();
		let name = core::str::from_utf8(&parsed.swissnum).unwrap();
		let root = session.fetch(name).await.unwrap();
		let attached = Attached::new(client.clone(), root.clone());
		let changed = Rc::new(Cell::new(0));
		let retired = Rc::new(Cell::new(false));
		let (snapshot, watching) = attached
			.watch(Views {
				changed: changed.clone(),
				retired: retired.clone(),
			})
			.await
			.unwrap();
		assert_eq!(snapshot.revision.get(), 0);
		assert_eq!(
			attached
				.command("facet-standing", 0, "setStanding", &["present".into()])
				.await
				.unwrap(),
			1
		);
		assert_eq!(changed.get(), 1, "snapshot delivery precedes durable reply");
		assert_eq!(attached.snapshot().await.unwrap().revision.get(), 1);
		let facet = attached
			.facet(rooms_application::grants::Rights::Observe)
			.await
			.unwrap();
		assert_eq!(
			facet.session.snapshot().await.unwrap().access,
			rooms_application::grants::Access::Observe
		);
		assert!(facet
			.session
			.command("not-authorized", 1, "setStanding", &["quiet".into()])
			.await
			.is_err());
		facet.revoke().await.unwrap();
		assert!(
			facet.session.snapshot().await.is_err(),
			"held facet refuses after revocation"
		);
		drop(watching);
		assert!(retired.get(), "watch Drop releases application captures immediately");
		if restart == 0 {
			commands
				.prepare_command(
					OperationId::new("disable-history".into()).unwrap(),
					1,
					Command::ChooseHistoryRetention,
					vec!["false".into()],
				)
				.unwrap()
				.send()
				.unwrap()
				.wait()
				.await
				.unwrap();
			assert_eq!(changed.get(), 1, "a retired watch cannot deliver another view");
		}
		application.close().await.unwrap();
		assert!(
			session.fetch(name).await.is_err(),
			"closed root is no longer discoverable"
		);
		assert!(
			session.send(&root, "snapshot", &[]).await.is_err(),
			"held root stops answering"
		);
	}
	drop((client, accepted));
	runtime.close(PendingWork::Cancel).await.unwrap();
	caller.close(PendingWork::Cancel).await.unwrap();
}
