//! The production composition keeps private startup custody across physical opens.
use super::*;
use managed::{Bootstrap, StartupAnchor};
use rooms_glowcap::client::workspace::EffectStatus;

#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn shared_opening_session_bootstrap_preserves_workspace_and_fences_publication() {
	run().await;
}
pub(super) async fn run() {
	tokio::task::LocalSet::new()
		.run_until(async {
			environment::within(10_000, async {
				let database = Database::new("opening");
				let schemas = managed::schemas();
				let mut limits = crate::session_storage::limits_for(
					24,
					8,
					loam::ValueBounds {
						values: 512,
						capabilities: 8,
						bytes: 65536,
						..Default::default()
					},
				);
				limits.pending_bytes = limits.call_bytes * limits.max_operations;
				limits.ingress_bytes = limits.pending_bytes;
				limits.max_leases *= limits.max_operations;
				limits.cache_slots = 3 * (limits.record_capacity + 2) + 5;
				limits.resident_bytes = limits.cache_slots * limits.record_bytes;
				let store = database.open(true, &schemas, limits).await;
				let policy = rooms_glowcap::policy::descriptor().unwrap();
				let payload =
					managed::initial_payload(rooms_application::content::session::workspace::Connection::Relay)
						.unwrap();
				let host = Host::from_seed([133; 32]).unwrap();
				let mut staged = store
					.stage_resource(&policy, schemas[0], session::KIND, &payload, 4, [137; 16])
					.unwrap();
				let prepared = staged.resource().encode();
				let probe_owner = managed::Session::new(
					host.clone(),
					Platform::default(),
					std::num::NonZeroUsize::new(65536).unwrap(),
				);
				assert!(
					store.attach(&host, vec![probe_owner.registration()]).is_err(),
					"uncommitted creation cannot acquire an attachment"
				);
				staged.abort().unwrap();
				let mut probe = store.attach(&host, vec![probe_owner.registration()]).unwrap();
				let missing = probe.restore(staged.resource()).await;
				assert_eq!(
					missing.expect_err("aborted root is absent").kind(),
					glowcap::ErrorKind::NotFound
				);
				probe.close().await.unwrap();
				drop(probe);
				let persisted = Rc::new(Cell::new(Bootstrap {
					seed: [133; 32],
					store_identity: [111; 16],
					owner_identity: [137; 16],
					anchor: Some(StartupAnchor {
						resource: loam::Resource::decode(prepared),
						marker: None,
					}),
				}));
				let locator = glowcap::Locator::bare("iroh", "opening-proof");
				let refused = persisted
					.get()
					.open(
						store,
						host.clone(),
						Platform::default(),
						managed::BootstrapOptions {
							reply_bytes: std::num::NonZeroUsize::new(65536).unwrap(),
							live_capacity: 128,
							initial_connection: rooms_application::content::session::workspace::Connection::Relay,
						},
						{
							let persisted = persisted.clone();
							move |bootstrap: Bootstrap| {
								let anchor = bootstrap.anchor.unwrap();
								std::future::ready(if anchor.marker.is_none() {
									assert_ne!(
										anchor.resource.encode(),
										prepared,
										"aborted provisional IDs never repeat"
									);
									persisted.set(bootstrap);
									Ok(())
								} else {
									Err(loam::refusal("bootstrap storage refused"))
								})
							}
						},
					)
					.await
					.err()
					.expect("persistence failure cannot expose use or control");
				assert_eq!(refused.message(), Some("bootstrap storage refused"));
				assert_eq!(
					refused.secondary_error_count(),
					0,
					"failed opening closes all physical owners"
				);
				let mut anchor = persisted.get().anchor.unwrap();
				assert!(anchor.marker.is_none(), "refused marker is never assumed persisted");
				host.close(PendingWork::Cancel).await.unwrap();
				let mut original = None;
				let mut revision = None;
				let mut previous_cursor: Option<String> = None;
				for _ in 0..2 {
					let store = database.open(false, &schemas, limits).await;
					let host = Host::from_seed([133; 32]).unwrap();
					let prior = anchor.marker;
					let mut opened = persisted
						.get()
						.open(
							store,
							host.clone(),
							Platform::default(),
							managed::BootstrapOptions {
								reply_bytes: std::num::NonZeroUsize::new(65536).unwrap(),
								live_capacity: 128,
								initial_connection: rooms_application::content::session::workspace::Connection::Relay,
							},
							{
								let persisted = persisted.clone();
								move |bootstrap: Bootstrap| {
									persisted.set(bootstrap);
									std::future::ready(Ok(()))
								}
							},
						)
						.await
						.unwrap();
					anchor = persisted.get().anchor.expect("anchor persisted before use is exposed");
					assert_eq!(
						StartupAnchor::decode(anchor.encode()).unwrap().encode(),
						anchor.encode()
					);
					assert!(anchor.marker.is_some());
					if let Some(prior) = prior {
						assert_eq!(anchor.marker, Some(prior), "restart advances the existing marker");
					}
					let link = opened.publish(&locator).await.unwrap();
					if let Some(original) = &original {
						assert_eq!(&link, original, "restart creates no new public branch");
					} else {
						original = Some(link);
					}
					let workspace = opened.workspace().unwrap();
					let activity = workspace.activity_reader().await.unwrap();
					let empty: serde_json::Value =
						serde_json::from_str(&activity.read("", false).await.unwrap()).unwrap();
					let cursor = empty["cursor"].as_str().unwrap().to_owned();
					if let Some(previous) = previous_cursor.as_ref() {
						assert_ne!(&cursor, previous, "same marker advances its activity incarnation");
						assert!(
							activity.read(previous, false).await.is_err(),
							"old cursor cannot select reopened activity"
						);
					}
					previous_cursor = Some(cursor);
					let snapshot = workspace.snapshot().await.unwrap();
					if let Some(revision) = revision {
						assert_eq!(snapshot.revision, revision, "restart changes no content revision");
						assert_eq!(snapshot.intent.standing.text().as_str(), Some("preserved"));
					} else {
						let command = workspace
							.prepare_command("preserve", snapshot.revision, "setStanding", &["preserved".into()])
							.await
							.unwrap();
						let conflict = workspace
							.prepare_command("conflict", snapshot.revision, "setStanding", &["stale".into()])
							.await
							.unwrap();
						assert_eq!(command.submit().await.unwrap(), EffectStatus::Committed);
						assert_eq!(
							conflict.submit().await.unwrap(),
							EffectStatus::Conflict,
							"a concurrent request cannot replace committed intent"
						);
						assert_eq!(conflict.submit().await.unwrap(), EffectStatus::Conflict);
						assert!(conflict.result().await.is_err(), "conflict installed no effect receipt");
						assert_eq!(
							conflict.operation(),
							"conflict",
							"refusal preserves the original request"
						);
						assert_eq!(command.submit().await.unwrap(), EffectStatus::Committed);
						assert_eq!(command.status().await.unwrap(), EffectStatus::Committed);
						assert_eq!(command.result().await.unwrap().as_str(), Some("null"));
						// The same use goes through a real CapTP recipient. Neither
						// client reconstructs authority from the publication name.
						let viewer = Host::from_seed([134; 32]).unwrap();
						let (client, accepted) = management::connect(&host, &viewer, opened.access().unwrap()).await;
						let bootstrap = client.session().fetch("management-bootstrap").await.unwrap();
						let access = client.session().send(&bootstrap, "get", &[]).await.unwrap();
						let remote = rooms_glowcap::client::workspace::Workspace::new(
							client.clone(),
							Ref::try_from(&access).unwrap(),
						);
						let replay = remote
							.prepare_command("preserve", snapshot.revision, "setStanding", &["preserved".into()])
							.await
							.unwrap();
						assert_eq!(replay.canonical(), command.canonical());
						assert_eq!(replay.submit().await.unwrap(), EffectStatus::Committed);
						assert_eq!(replay.result().await.unwrap().as_str(), Some("null"));
						assert_eq!(
							remote.snapshot().await.unwrap().intent.standing.text().as_str(),
							Some("preserved")
						);
						let candidate = remote.snapshot().await.unwrap();
						let acquisition = remote
							.prepare_acquisition(candidate.revision, Vec::new(), &[], &candidate.intent)
							.unwrap();
						acquisition.submit().await.unwrap();
						acquisition.submit().await.unwrap();
						assert_eq!(remote.snapshot().await.unwrap().revision, candidate.revision);
						drop(acquisition);
						drop((remote, replay, bootstrap, access));
						client.relinquish().await.unwrap();
						accepted.close(PendingWork::Cancel).await.unwrap();
						viewer.close(PendingWork::Cancel).await.unwrap();
						revision = Some(workspace.snapshot().await.unwrap().revision);
					}
					let described = opened.management().unwrap().describe().await.unwrap();
					let loam::ControlDescription::Available(view) = described.view() else {
						panic!("public management")
					};
					assert!(view.inspect && view.issue_ceiling.is_some() && view.edit_ceiling.is_some());
					assert!(
						host.send(opened.access().unwrap(), "initialize", &[]).await.is_err(),
						"a public child cannot initialize the private root"
					);
					opened.close().await.unwrap();
					assert!(
						activity.read("", false).await.is_err(),
						"held reader refuses after physical close"
					);
					drop(opened);
					host.close(PendingWork::Cancel).await.unwrap();
				}
				database.remove();
				#[cfg(target_arch = "wasm32")]
				super::browser_bootstrap::run(limits).await;
			})
			.await
			.expect("shared session opening deadline");
		})
		.await;
}
