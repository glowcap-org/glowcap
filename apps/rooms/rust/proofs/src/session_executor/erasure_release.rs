//! A history erasure has no executor job, so the receipt that names it is
//! pending while the session's record names it, whether an attempt is in
//! flight or has failed and waits to be retried. Releasing that receipt, or
//! sweeping it because its sender's access was revoked, must leave it, or its
//! settlement is refused and history retention can never be chosen again.
use super::retention::Erasure;
use super::*;
use rooms_glowcap::client::workspace::{EffectStatus, Release};
use rooms_runtime::archive::session::SessionArchive;
use std::{cell::RefCell, num::NonZeroUsize, rc::Rc};

/// Scheduler turns the revoked-receipt sweep is given to run after the
/// revocation is visible.
const SWEEP_TURNS: usize = 2_000;

/// What the test sends and checks after its erasure is pending.
enum After {
	/// The sender releases its pending erasure.
	Release,
	/// The sender's access is revoked, so the revoked receipt owner sweeps.
	Revoke,
	/// The first erasure attempt fails and no attempt runs when the sender
	/// releases, then a retry succeeds.
	Failed,
}

async fn run(name: &'static str, after: After) {
	tokio::task::LocalSet::new()
		.run_until(async {
			environment::within(15_000, async {
				let database = Database::new(name);
				let schemas = managed::schemas();
				let limits = managed::production_limits().unwrap();
				let bootstrap = managed::Bootstrap {
					seed: [151; 32],
					store_identity: [111; 16],
					owner_identity: [141; 16],
					anchor: None,
				};
				let host = Host::from_seed_with_options([151; 32], rooms_glowcap::host_options()).unwrap();
				let platform = Platform::default();
				let runtime = Rc::new(
					glowcap::Runtime::open(glowcap::RuntimeConfig::connectors([]).adopt_host(&host))
						.await
						.unwrap(),
				);
				let store = database.open(true, &schemas, limits).await;
				let mut opened = bootstrap
					.open(
						store,
						host.clone(),
						platform.clone(),
						managed::BootstrapOptions {
							reply_bytes: NonZeroUsize::new(65536).unwrap(),
							live_capacity: 128,
							initial_connection: rooms_application::content::session::workspace::Connection::Relay,
						},
						|_| std::future::ready(Ok(())),
					)
					.await
					.unwrap();
				let failing = matches!(after, After::Failed);
				let hold = Rc::new(Cell::new(!failing));
				let refuse = Rc::new(Cell::new(failing));
				let reports = Rc::new(RefCell::new(Vec::<(String, String)>::new()));
				opened
					.session()
					.on_trouble({
						let reports = reports.clone();
						move |scope, cause| reports.borrow_mut().push((scope.to_owned(), cause.to_string()))
					})
					.unwrap();
				let sources = Rc::new(RefCell::new(Vec::new()));
				let (archive, worker) = SessionArchive::new(
					platform.clone(),
					runtime.clone(),
					Erasure {
						refuse: refuse.clone(),
						hold: hold.clone(),
						sources: sources.clone(),
					},
				);
				let archive = Rc::new(archive);
				let worker = tokio::task::spawn_local(worker.run());
				opened.record_to(archive.clone(), "recorder".into()).unwrap();
				let workspace = opened.workspace().unwrap();
				let base = workspace.snapshot().await.unwrap().revision;
				let request = workspace
					.prepare_command("erase-original", base, "chooseHistoryRetention", &["false".into()])
					.await
					.unwrap();
				assert_eq!(request.submit().await.unwrap(), EffectStatus::Pending);
				while sources.borrow().is_empty() {
					tokio::task::yield_now().await;
				}
				match after {
					After::Release => {
						assert_eq!(
							request.release().await.unwrap(),
							Release::Running,
							"a pending erasure's receipt is not released under it"
						);
						assert_eq!(request.status().await.unwrap(), EffectStatus::Pending);
						let pending = workspace.snapshot().await.unwrap();
						assert!(pending.intent.history_erasure.is_some(), "the release changed nothing");
						hold.set(false);
						while request.status().await.unwrap() != EffectStatus::Committed {
							environment::yield_turn().await;
						}
						let settled = workspace.snapshot().await.unwrap();
						assert!(settled.intent.history_erasure.is_none(), "the erasure settled");
						let enable = workspace
							.prepare_command(
								"enable-after-erasure",
								settled.revision,
								"chooseHistoryRetention",
								&["true".into()],
							)
							.await
							.unwrap();
						assert_eq!(
							enable.submit().await.unwrap(),
							EffectStatus::Committed,
							"retention can be chosen again"
						);
					}
					After::Failed => {
						// The attempt failed and the worker waits for a retry. The
						// failure reaches the session's trouble report with its
						// cause, and the receipt is still pending.
						while !reports.borrow().iter().any(|(scope, cause)| {
							scope == "History retention" && cause.contains("injected erasure refusal")
						}) {
							environment::yield_turn().await;
						}
						assert_eq!(request.status().await.unwrap(), EffectStatus::Pending);
						assert_eq!(
							request.release().await.unwrap(),
							Release::Running,
							"a failed erasure's receipt is not released while the record names it"
						);
						assert!(
							workspace.snapshot().await.unwrap().intent.history_erasure.is_some(),
							"the release changed nothing"
						);
						refuse.set(false);
						opened.session().resume_pending().unwrap();
						while request.status().await.unwrap() != EffectStatus::Committed {
							environment::yield_turn().await;
						}
						let settled = workspace.snapshot().await.unwrap();
						assert!(
							settled.intent.history_erasure.is_none(),
							"the retry settled the erasure"
						);
						let enable = workspace
							.prepare_command(
								"enable-after-failed-erasure",
								settled.revision,
								"chooseHistoryRetention",
								&["true".into()],
							)
							.await
							.unwrap();
						assert_eq!(
							enable.submit().await.unwrap(),
							EffectStatus::Committed,
							"retention can be chosen again"
						);
					}
					After::Revoke => {
						let management = opened.management().unwrap();
						let revision = management::revision(&management).await;
						management.revoke(revision).await.unwrap();
						// The sender sees its revocation once the session applies it, and
						// the sweep wakes on the same change. The sweep reports nothing
						// when it ends, so it is given scheduler turns, not wall time,
						// and it must find the pending erasure running and leave its
						// receipt.
						while workspace.snapshot().await.is_ok() {
							environment::yield_turn().await;
						}
						for _ in 0..SWEEP_TURNS {
							environment::yield_turn().await;
						}
						hold.set(false);
						// The erasure settles once released, and the session cannot
						// close before it does.
					}
				}
				drop((request, workspace));
				opened
					.close()
					.await
					.expect("the erasure settled, so the session closes");
				drop(opened);
				archive.close().await.unwrap();
				worker.await.unwrap();
				runtime.close(PendingWork::Cancel).await.unwrap();
				database.remove();
			})
			.await
			.expect("erasure release deadline");
		})
		.await;
}

#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn releasing_a_pending_history_erasure_answers_running_and_leaves_retention_choosable() {
	run("erasure-release", After::Release).await;
}

#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn a_revoked_senders_pending_history_erasure_is_not_swept_until_it_settles() {
	run("erasure-revoked", After::Revoke).await;
}

#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn releasing_a_failed_history_erasure_answers_running_and_its_retry_settles() {
	run("erasure-failed", After::Failed).await;
}
