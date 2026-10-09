//! Editor and worker restoration select exact fields through the private owner.
//! Even a public workspace with every permission cannot recover stored controls.
use super::*;
use glowcap::loam::{AccessStatus, ControlDescription};
use rooms_application::{content::permissions::Permission, fields::Text};
use rooms_glowcap::client::{
	access::{Control, Issuance},
	workspace::{Import, Workspace},
};

#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn retained_session_controls_survive_restart_without_public_authority_recovery() {
	run().await;
}
pub(super) async fn run() {
	tokio::task::LocalSet::new()
		.run_until(async {
			environment::within(10_000, async {
				let database = Database::new("retained-controls");
				let schemas = managed::schemas();
				let limits = managed::production_limits().unwrap();
				let persisted = Rc::new(Cell::new(managed::Bootstrap {
					seed: [151; 32],
					store_identity: [111; 16],
					owner_identity: [152; 16],
					anchor: None,
				}));
				let access = requests::coordinate(custody::Role::SessionAccess, 7);
				let control = requests::coordinate(custody::Role::SessionControl, 7);
				let selections = [access, control];
				for reopening in [false, true] {
					let store = database.open(!reopening, &schemas, limits).await;
					let host = Host::from_seed([151; 32]).unwrap();
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
								move |bootstrap| {
									persisted.set(bootstrap);
									std::future::ready(Ok(()))
								}
							},
						)
						.await
						.unwrap();
					let workspace = opened.workspace().unwrap();
					if !reopening {
						let policy = rooms_glowcap::policy::descriptor().unwrap();
						let observe = policy
							.value_for_kind(session::KIND, &[Permission::ObserveWorkspace.key()], &[])
							.unwrap();
						let management = opened.management().unwrap();
						let request = Issuance::new(
							observe.with_ceiling(observe),
							management.derivation_sequence().await.unwrap(),
							management::revision(&management).await,
							0,
							ControlPowers {
								inspect: true,
								pause: true,
								resume: true,
								revoke: true,
								policy_ceiling: Some(observe),
								..Default::default()
							},
							"separate management",
							false,
						);
						let issued = management.issue(&request).await.unwrap();
						let mut snapshot = workspace.snapshot().await.unwrap();
						snapshot
							.intent
							.accesses
							.try_push(session::workspace::Access {
								id: Text::new("observer".into()).unwrap(),
								access: Some(custody::FieldKey::new(access.key.slot(), access.key.generation())),
								control: Some(custody::FieldKey::new(control.key.slot(), control.key.generation())),
							})
							.unwrap();
						let acquisition = workspace
							.prepare_acquisition(
								snapshot.revision,
								vec![
									Import {
										coordinate: access,
										reference: issued.access.clone(),
										uri: None,
									},
									Import {
										coordinate: control,
										reference: issued.control.clone(),
										uri: None,
									},
								],
								&[],
								&snapshot.intent,
							)
							.unwrap();
						acquisition.submit().await.unwrap();
						let held = opened.session().restore_custody(&selections).await.unwrap();
						assert_eq!(
							held,
							vec![issued.access, issued.control],
							"no widening or reissuance on restoration"
						);
					}
					let public_request = Argument::List(
						selections
							.iter()
							.map(|coordinate| serde_json::to_string(coordinate).unwrap().into())
							.collect(),
					);
					let mut wrong_generation = control;
					wrong_generation.key = custody::FieldKey::new(control.key.slot(), NonZeroU64::new(2).unwrap());
					let absent_request = Argument::List(vec![serde_json::to_string(&wrong_generation).unwrap().into()]);
					// Refuse before metadata lookup and reference restoration, for
					// present and absent coordinates alike. Every workspace permission
					// still confers neither private ingress nor saved control custody.
					let viewer = Host::from_seed([153; 32]).unwrap();
					let (client, accepted) = management::connect(&host, &viewer, opened.access().unwrap()).await;
					let bootstrap = client.session().fetch("management-bootstrap").await.unwrap();
					let remote = Ref::try_from(&client.session().send(&bootstrap, "get", &[]).await.unwrap()).unwrap();
					let mut refusal = None;
					for selected in [public_request, absent_request] {
						for with_uri in [false, true] {
							let mut local_args = vec![opened.access().unwrap().clone().into(), selected.clone()];
							let mut remote_args = vec![remote.clone().into(), selected.clone()];
							if with_uri {
								local_args.push(Argument::Boolean(true));
								remote_args.push(Argument::Boolean(true));
							}
							let local_error = host
								.send(opened.access().unwrap(), "restore-custody", &local_args)
								.await
								.unwrap_err();
							assert_eq!(local_error.message(), Some("ApplicationRefused"));
							let remote_error = client
								.session()
								.send(&remote, "restore-custody", &remote_args)
								.await
								.unwrap_err();
							let errors = (local_error.to_string(), remote_error.to_string());
							if let Some(prior) = &refusal {
								assert_eq!(prior, &errors, "public refusal cannot reveal custody presence");
							}
							refusal = Some(errors);
						}
					}
					drop((remote, bootstrap, client, accepted));
					viewer.close(PendingWork::Cancel).await.unwrap();
					assert!(opened.session().restore_custody(&[wrong_generation]).await.is_err());
					let held = opened.session().restore_custody(&selections).await.unwrap();
					let published = opened.session().restore_publication_custody(&selections).await.unwrap();
					assert_eq!(published, vec![(held[0].clone(), None), (held[1].clone(), None)]);
					let reader = Workspace::local(host.clone(), Platform::default(), held[0].clone());
					let management = Control::local(host.clone(), Platform::default(), held[1].clone());
					assert_eq!(workspace.snapshot().await.unwrap().intent.accesses.as_slice().len(), 1);
					let revision = management::revision(&management).await;
					if !reopening {
						management.pause(revision).await.unwrap();
					} else {
						let state = management.describe().await.unwrap();
						assert!(
							matches!(state.view(), ControlDescription::Available(view) if view.status == AccessStatus::Paused)
						);
						assert!(
							reader.snapshot().await.is_err(),
							"paused use stays paused after restart"
						);
						management.resume(revision).await.unwrap();
						reader.snapshot().await.unwrap();
						management
							.revoke(management::revision(&management).await)
							.await
							.unwrap();
						assert!(reader.snapshot().await.is_err());
						assert!(
							management.resume(revision).await.is_err(),
							"revoked access cannot be revived"
						);
					}
					drop((held, reader, management, workspace));
					opened.close().await.unwrap();
					drop(opened);
					host.close(PendingWork::Cancel).await.unwrap();
				}
				database.remove();
			})
			.await
			.expect("private custody deadline");
		})
		.await;
}
