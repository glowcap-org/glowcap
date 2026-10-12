//! Physical Loam reopen recovers an owner-scoped erasure after interruption.
//! The fake archive controls erasure failure. Process archive and IndexedDB
//! browser journeys separately establish record/blob storage commitment.
use super::*;
use rooms_application::archive::{
	Filter, Record,
	index::{Index, Page},
};
use rooms_glowcap::client::workspace::EffectStatus;
use rooms_runtime::archive::{Backend, session::SessionArchive};
use std::{cell::RefCell, num::NonZeroUsize, rc::Rc};

struct Erasure {
	refuse: Rc<Cell<bool>>,
	sources: Rc<RefCell<Vec<rooms_application::text::DocumentText>>>,
}
impl Backend for Erasure {
	async fn put(&mut self, _: Record) -> core::result::Result<u64, rooms_runtime::Error> {
		unreachable!("no producer in recovery fixture")
	}
	async fn read(
		&mut self,
		filter: &Filter,
		after: u64,
		limit: usize,
	) -> core::result::Result<Page, rooms_runtime::Error> {
		Index::new(1)
			.unwrap()
			.read(filter, after, limit)
			.map_err(rooms_runtime::Error::invalid_by)
	}
	async fn clear_source(
		&mut self,
		source: &rooms_application::text::DocumentText,
	) -> core::result::Result<(), rooms_runtime::Error> {
		self.sources.borrow_mut().push(source.clone());
		if self.refuse.get() {
			Err(rooms_runtime::Error::storage(std::io::Error::other(
				"injected erasure refusal",
			)))
		} else {
			Ok(())
		}
	}
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn pending_history_erasure_survives_physical_owner_reopen_and_fences_configuration() {
	if std::env::var_os("GLOWCAP_ROOMS_RETENTION_RECOVERY_DB").is_some() {
		run().await;
		return;
	}
	let database = Database::new("retention-recovery-process");
	for phase in ["interrupt", "recover"] {
		let mut child = std::process::Command::new(std::env::current_exe().unwrap())
			.args([
				"pending_history_erasure_survives_physical_owner_reopen_and_fences_configuration",
				"--nocapture",
			])
			.env("GLOWCAP_ROOMS_RETENTION_RECOVERY_DB", database.path())
			.env("GLOWCAP_ROOMS_RETENTION_RECOVERY_PHASE", phase)
			.spawn()
			.unwrap();
		let status = environment::within(15_000, async {
			loop {
				if let Some(status) = child.try_wait().unwrap() {
					break status;
				}
				tokio::time::sleep(std::time::Duration::from_millis(10)).await;
			}
		})
		.await;
		if status.is_none() {
			child.kill().unwrap();
			child.wait().unwrap();
		}
		assert!(status.expect("recovery child deadline").success(), "retention {phase}");
	}
	database.remove();
}

pub(super) async fn run() {
	tokio::task::LocalSet::new()
		.run_until(async {
			environment::within(10_000, async {
				#[cfg(target_arch = "wasm32")]
				let database = Database::new("retention-recovery");
				#[cfg(not(target_arch = "wasm32"))]
				let database = Database::at(std::env::var_os("GLOWCAP_ROOMS_RETENTION_RECOVERY_DB").unwrap().into());
				let schemas = managed::schemas();
				let limits = managed::production_limits().unwrap();
				let bootstrap = Rc::new(Cell::new(managed::Bootstrap {
					seed: [139; 32],
					store_identity: [111; 16],
					owner_identity: [141; 16],
					anchor: None,
				}));
				let refuse = Rc::new(Cell::new(true));
				let sources = Rc::new(RefCell::new(Vec::new()));
				let mut original_base = None;
				#[cfg(target_arch = "wasm32")]
				let reopenings = vec![false, true];
				#[cfg(not(target_arch = "wasm32"))]
				let reopenings = {
					let reopening = std::env::var("GLOWCAP_ROOMS_RETENTION_RECOVERY_PHASE").unwrap() == "recover";
					if reopening {
						bootstrap.set(
							managed::Bootstrap::decode(
								std::fs::read(database.path().join("bootstrap"))
									.unwrap()
									.try_into()
									.unwrap(),
							)
							.unwrap(),
						);
						original_base = Some(
							std::fs::read_to_string(database.path().join("base"))
								.unwrap()
								.parse::<u64>()
								.unwrap(),
						);
						refuse.set(false);
					}
					vec![reopening]
				};
				for reopening in reopenings {
					let platform = Platform::default();
					let host = Host::from_seed_with_options([139; 32], rooms_glowcap::host_options()).unwrap();
					let runtime = Rc::new(
						glowcap::Runtime::open(glowcap::RuntimeConfig::connectors([]).adopt_host(&host))
							.await
							.unwrap(),
					);
					let store = database.open(!reopening, &schemas, limits).await;
					let mut opened = bootstrap
						.get()
						.open(
							store,
							host.clone(),
							platform.clone(),
							managed::BootstrapOptions {
								reply_bytes: NonZeroUsize::new(65536).unwrap(),
								live_capacity: 128,
								initial_connection: rooms_application::content::session::workspace::Connection::Relay,
							},
							{
								let bootstrap = bootstrap.clone();
								move |value| {
									bootstrap.set(value);
									std::future::ready(Ok(()))
								}
							},
						)
						.await
						.unwrap();
					let (archive, worker) = SessionArchive::new(
						platform.clone(),
						runtime.clone(),
						Erasure {
							refuse: refuse.clone(),
							sources: sources.clone(),
						},
					);
					let archive = Rc::new(archive);
					let worker = tokio::task::spawn_local(worker.run());
					opened.record_to(archive.clone(), "recorder".into()).unwrap();
					let workspace = opened.workspace().unwrap();
					let snapshot = workspace.snapshot().await.unwrap();
					let base = *original_base.get_or_insert(snapshot.revision);
					let request = workspace
						.prepare_command("erase-original", base, "chooseHistoryRetention", &["false".into()])
						.await
						.unwrap();
					if !reopening {
						assert_eq!(request.submit().await.unwrap(), EffectStatus::Pending);
						while request.status().await.unwrap() == EffectStatus::Pending {
							tokio::task::yield_now().await;
						}
						assert!(!sources.borrow().is_empty(), "erasure was admitted before its failure");
						let pending = workspace.snapshot().await.unwrap();
						assert!(!pending.intent.keep_history);
						assert_eq!(
							pending.intent.history_erasure.as_ref().unwrap().text().as_str(),
							Some("erase-original")
						);
						let enable = workspace
							.prepare_command(
								"premature-enable",
								pending.revision,
								"chooseHistoryRetention",
								&["true".into()],
							)
							.await
							.unwrap();
						assert!(
							enable.submit().await.is_err(),
							"enabling cannot bypass admitted erasure"
						);
						let mut imported = pending.intent;
						imported.history_erasure = None;
						assert!(
							host.send(
								workspace.reference(),
								"replaceWorkspace",
								&[serde_json::to_string(&imported).unwrap().into()]
							)
							.await
							.is_err()
						);
						assert!(
							opened.close().await.is_err(),
							"failed erasure retains the close barrier"
						);
						#[cfg(not(target_arch = "wasm32"))]
						{
							std::fs::write(database.path().join("bootstrap"), bootstrap.get().encode()).unwrap();
							std::fs::write(database.path().join("base"), base.to_string()).unwrap();
							std::fs::write(database.path().join("source"), sources.borrow()[0].as_str().unwrap())
								.unwrap();
							// No Rust Drop or graceful cancellation runs. The next process
							// restores the physically committed marker and original receipt.
							std::process::exit(0);
						}
						#[cfg(target_arch = "wasm32")]
						{
							// IndexedDB failure recovery is exercised in the same owner;
							// physical process interruption belongs to the child process.
							refuse.set(false);
							// Shutdown fences public calls. Retry the retained private
							// close barrier; inspect the receipt only after cold reopen.
							opened.close().await.unwrap();
						}
					} else {
						while request.status().await.unwrap() != EffectStatus::Committed {
							environment::yield_turn().await;
						}
						let settled = workspace.snapshot().await.unwrap();
						assert!(!settled.intent.keep_history);
						assert!(settled.intent.history_erasure.is_none());
						let attempts = sources.borrow().len();
						assert_eq!(request.submit().await.unwrap(), EffectStatus::Committed);
						assert_eq!(
							sources.borrow().len(),
							attempts,
							"receipt replay performs no fresh erasure"
						);
						let enable = workspace
							.prepare_command(
								"enable-after-erasure",
								settled.revision,
								"chooseHistoryRetention",
								&["true".into()],
							)
							.await
							.unwrap();
						assert_eq!(enable.submit().await.unwrap(), EffectStatus::Committed);
						opened.close().await.unwrap();
					}
					drop((request, workspace, opened));
					archive.close().await.unwrap();
					worker.await.unwrap();
					runtime.close(PendingWork::Cancel).await.unwrap();
					drop((archive, runtime, host));
					refuse.set(false);
				}
				#[cfg(target_arch = "wasm32")]
				assert!(sources.borrow().len() >= 2);
				#[cfg(not(target_arch = "wasm32"))]
				assert_eq!(
					sources.borrow()[0].as_str().unwrap(),
					std::fs::read_to_string(database.path().join("source")).unwrap()
				);
				assert!(
					sources.borrow().iter().all(|source| source == &sources.borrow()[0]),
					"reopen keeps the exact recorder account"
				);
				#[cfg(target_arch = "wasm32")]
				database.remove();
			})
			.await
			.expect("retention recovery deadline");
		})
		.await;
}
