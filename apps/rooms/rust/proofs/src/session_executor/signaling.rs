//! Ephemeral signaling never follows a replaced registration or source.
use super::*;
use rooms_application::signaling as policy;
use rooms_glowcap::client::workspace::Workspace;
use std::num::NonZeroUsize;

#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn signaling_keeps_exact_name_source_and_directory_selection() {
	run().await;
}

pub(super) async fn run() {
	tokio::task::LocalSet::new()
		.run_until(async {
			environment::within(10_000, async {
				let database = Database::new("signaling-source");
				let schemas = managed::schemas();
				let mut limits = managed::reader_limits(crate::session_storage::limits_for(
					24,
					8,
					loam::ValueBounds {
						values: 32,
						capabilities: 4,
						bytes: 8192,
						..Default::default()
					},
				))
				.unwrap();
				// Three overlapping managed turns each retain a record window and
				// two spine rows; five shared owner/feed rows remain resident.
				limits.cache_slots = 3 * (limits.record_capacity + 2) + 5;
				limits.resident_bytes = limits.cache_slots * limits.record_bytes;
				limits.max_leases = limits.cache_slots * limits.max_operations;
				// Two parked shared observations coexist with signaling checks
				// and management edits. Use the declared operation population.
				limits.pending_bytes = limits.call_bytes * limits.max_operations;
				limits.ingress_bytes = limits.pending_bytes;
				let mut store = database.open(true, &schemas, limits).await;
				let descriptor = rooms_glowcap::policy::descriptor().unwrap();
				let resource = environment::create(
					&store,
					&descriptor,
					schemas[0],
					&managed::initial_payload(rooms_application::content::session::workspace::Connection::Relay)
						.unwrap(),
					3,
				)
				.await;
				let host = Host::from_seed([125; 32]).unwrap();
				let platform = Platform::default();
				let owner = managed::Session::new(host.clone(), platform.clone(), NonZeroUsize::new(8192).unwrap());
				let calls = Rc::new(Cell::new(0));
				let refuse_route = Rc::new(Cell::new(false));
				let refused_routes = Rc::new(Cell::new(0));
				let target = host
					.spawn({
						let calls = calls.clone();
						let refuse_route = refuse_route.clone();
						let refused_routes = refused_routes.clone();
						move |verb, _| {
							let verb = verb.ok_or("fixture requires a method")?;
							if verb == policy::CHECK {
								if refuse_route.get() {
									refused_routes.set(refused_routes.get() + 1);
									return Err("injected upstream observation failure".into());
								}
								return Ok(Argument::Void);
							}
							assert!(
								[
									policy::OFFER_INBOX,
									policy::OFFER,
									policy::ANSWER,
									policy::CANDIDATE,
									policy::DONE
								]
								.contains(&verb)
							);
							calls.set(calls.get() + 1);
							Ok(Argument::Void)
						}
					})
					.unwrap();
				let mut attachment = store.attach(&host, vec![owner.registration()]).unwrap();
				environment::start_live(&attachment, None, 32).await;
				let (root, root_control) = environment::restore(&attachment, resource).await;
				owner.bind(root.clone(), root_control.clone()).unwrap();
				owner.initialize().await.unwrap();
				let terms = descriptor
					.value_for_kind(
						session::KIND,
						&session::SUPPORTED.iter().map(|p| p.key()).collect::<Vec<_>>(),
						&[],
					)
					.unwrap();
				let (source, control) = owner
					.derive(
						terms,
						1,
						ControlPowers {
							pause: true,
							resume: true,
							revoke: true,
							..Default::default()
						},
					)
					.await
					.unwrap();
				let (sibling, _) = owner.derive(terms, 0, ControlPowers::default()).await.unwrap();
				for slot in [1, 2] {
					owner
						.import(
							requests::coordinate(custody::Role::DirectoryName, slot),
							target.clone(),
							None,
						)
						.await
						.unwrap();
					owner
						.import(
							requests::coordinate(custody::Role::DirectoryAccess, slot),
							source.clone(),
							None,
						)
						.await
						.unwrap();
					owner
						.import(
							requests::coordinate(custody::Role::SessionAccess, slot),
							source.clone(),
							None,
						)
						.await
						.unwrap();
				}
				let mut intent = Intent::empty();
				intent.directories = serde_json::from_value(serde_json::json!([{
					"id":"directory", "access":key::<custody::DirectoryAccess>(), "name":key::<custody::DirectoryName>(),
					"source":key::<custody::SessionAccess>(), "home":true, "nick":"peer", "nickAllocation":"exact", "standing":null
				}]))
				.unwrap();
				owner.replace_workspace(&intent).await.unwrap();
				let selected =
					session::workspace::SignalingSelection::directory(&intent.directories.as_slice()[0]).unwrap();
				let workspace = Workspace::local(host.clone(), platform.clone(), source.clone());
				let route = workspace.signaling(&selected).await.unwrap();
				route.check().await.unwrap();
				let encoded = serde_json::to_string(&selected).unwrap();
				let facade = Ref::try_from(
					&host
						.send(&source, "signaling-route", &[encoded.clone().into()])
						.await
						.unwrap(),
				)
				.unwrap();
				let inbox = host.spawn(|_, _| Ok(Argument::Void)).unwrap();
				route.offer_signaling(&inbox).await.unwrap();
				for (verb, args) in [
					(policy::OFFER, vec!["peer".into(), "offer".into(), inbox.clone().into()]),
					(policy::ANSWER, vec!["exchange".into(), "answer".into()]),
					(policy::CANDIDATE, vec!["exchange".into(), "candidate".into()]),
					(policy::DONE, vec!["exchange".into()]),
				] {
					host.send(&facade, verb, &args).await.unwrap();
				}
				assert_eq!(calls.get(), 5);
				// Exercise sessionless notification delivery through the same facade.
				route
					.signal_candidate(
						&policy::Id::parse("exchange").unwrap(),
						&policy::Candidate::parse("candidate").unwrap(),
					)
					.unwrap();
				host.send(&source, "snapshot", &[]).await.unwrap();
				assert_eq!(calls.get(), 6);
				for verb in ["leave", "voucher", "register"] {
					assert!(host.send(&facade, verb, &[]).await.is_err());
				}
				assert!(
					Workspace::local(host.clone(), platform.clone(), sibling.clone())
						.signaling(&selected)
						.await
						.is_err()
				);
				let mut registration = owner
					.signaling_registration(&intent.directories.as_slice()[0])
					.await
					.unwrap();
				registration.ready().await.unwrap();
				// Observation failure is not authority loss. The same registration
				// remains charged until its feeds and source checks recover.
				platform.refuse_observation.set(true);
				owner.replace_workspace(&intent).await.unwrap();
				while !matches!(registration.status(), Some(Err(_))) {
					environment::yield_turn().await;
				}
				platform.refuse_observation.set(false);
				assert!(
					owner
						.signaling_registration(&intent.directories.as_slice()[0])
						.await
						.is_err(),
					"duplicate signaling owner: {:?}; host failures: {:?}",
					registration.status(),
					host.take_failures()
				);
				assert!(
					matches!(registration.status(), Some(Err(_))),
					"recovery requires explicit retry"
				);
				registration.retry();
				registration.ready().await.unwrap();
				// A broken route reply also carries no affirmative authority verdict.
				refuse_route.set(true);
				owner.replace_workspace(&intent).await.unwrap();
				while !matches!(registration.status(), Some(Err(_))) {
					environment::yield_turn().await;
				}
				let failures = refused_routes.get();
				assert!(failures > 0);
				for _ in 0..3 {
					environment::yield_turn().await;
				}
				assert_eq!(refused_routes.get(), failures, "failed supervision must not spin");
				assert!(
					owner
						.signaling_registration(&intent.directories.as_slice()[0])
						.await
						.is_err()
				);
				refuse_route.set(false);
				registration.retry();
				registration.ready().await.unwrap();
				publication_results::lifecycle(&host, &control, "pause").await;
				registration.retired().await;
				registration.close().await.unwrap();
				assert!(route.offer_signaling(&inbox).await.is_err());
				assert!(route.check().await.is_err());
				publication_results::lifecycle(&host, &control, "resume").await;
				route.offer_signaling(&inbox).await.unwrap();
				assert_eq!(calls.get(), 7);
				for changed in ["name", "source", "access"] {
					let mut registration = owner
						.signaling_registration(&intent.directories.as_slice()[0])
						.await
						.unwrap();
					let mut replacement = intent.clone();
					let row = &mut replacement.directories.as_mut_slice()[0];
					match changed {
						"name" => {
							row.name = Some(custody::FieldKey::new(
								NonZeroU64::new(2).unwrap(),
								NonZeroU64::new(1).unwrap(),
							))
						}
						"source" => {
							row.source = Some(custody::FieldKey::new(
								NonZeroU64::new(2).unwrap(),
								NonZeroU64::new(1).unwrap(),
							))
						}
						_ => {
							row.access =
								custody::FieldKey::new(NonZeroU64::new(2).unwrap(), NonZeroU64::new(1).unwrap())
						}
					}
					owner.replace_workspace(&replacement).await.unwrap();
					registration.retired().await;
					registration.close().await.unwrap();
					assert!(
						route.offer_signaling(&inbox).await.is_err(),
						"retained route follows no replacement {changed}"
					);
					assert!(route.check().await.is_err());
					assert!(workspace.signaling(&selected).await.is_err());
					assert_eq!(calls.get(), 7);
					owner.replace_workspace(&intent).await.unwrap();
				}
				publication_results::lifecycle(&host, &control, "revoke").await;
				assert!(route.offer_signaling(&inbox).await.is_err());
				assert_eq!(calls.get(), 7);
				owner.close().await.unwrap();
				drop((
					route,
					facade,
					inbox,
					workspace,
					target,
					source,
					control,
					sibling,
					root,
					root_control,
					owner,
				));
				attachment.close().await.unwrap();
				host.close(PendingWork::Cancel).await.unwrap();
				environment::close(&mut store).await;
				database.remove();
			})
			.await
			.expect("signaling source proof deadline");
		})
		.await;
}
