//! The receipt execution scenario keeps exact targets across interruption and cold reopen.
use super::*;

pub(super) async fn run(case: Case) {
	tokio::task::LocalSet::new()
		.run_until(async {
			environment::within(10_000, async {
				let database = Database::new(case.verb);
				let mut schemas = managed::schemas();
				schemas.push(TARGET);
				let mut limits = crate::session_storage::limits_for(
					16,
					8,
					loam::ValueBounds {
						values: 16,
						capabilities: 4,
						bytes: 4096,
						..Default::default()
					},
				);
				// Local observation, continuation admission and private settlement
				// overlap on one ingress. Reserve the declared operation population
				// there as well as at the attachment; call backing remains lazy.
				limits.pending_bytes = limits.call_bytes.checked_mul(limits.max_operations).unwrap();
				limits.ingress_bytes = limits.pending_bytes;
				// Each concurrent preparation can pin the same resident rows;
				// lease occurrences are independent of physical cache residency.
				limits.max_leases = limits.max_leases.checked_mul(limits.max_operations).unwrap();
				let mut store = database.open(true, &schemas, limits).await;
				let policy = rooms_glowcap::policy::descriptor().unwrap();
				let resource = environment::create(
					&store,
					&policy,
					schemas[0],
					&managed::initial_payload(rooms_application::content::session::workspace::Connection::Relay)
						.unwrap(),
					3,
				)
				.await;
				let operator = environment::create(&store, &policy, TARGET, b"original", 1).await;
				let replacement = environment::create(&store, &policy, TARGET, b"replacement", 1).await;
				let host = Host::from_seed([112; 32]).unwrap();
				host.set_advertised_locator(&glowcap::Locator::bare("tcp", "127.0.0.1:9012"))
					.unwrap();
				let platform = Platform::default();
				let owner = managed::Session::new(
					host.clone(),
					platform.clone(),
					std::num::NonZeroUsize::new(4096).unwrap(),
				);
				let calls = Rc::new(Cell::new(0));
				let revoked = Rc::new(std::cell::RefCell::new(None));
				let malformed = Rc::new(Cell::new(false));
				let refuse = Rc::new(Cell::new(false));
				let refuse_settlement = Rc::new(Cell::new(false));
				let mut registration = owner.registration();
				registration.content = Box::new(AbortAfterAdmission {
					inner: registration.content,
					refuse: refuse.clone(),
					refuse_settlement: refuse_settlement.clone(),
				});
				let mut attachment = store
					.attach(
						&host,
						vec![
							registration,
							target_registration_with_token(calls.clone(), malformed.clone(), &case, revoked.clone()),
						],
					)
					.unwrap();
				if case.role.live() {
					attachment.start_live(None, 32).unwrap();
				}
				let (root, root_control) = environment::restore(&attachment, resource).await;
				owner.bind(root.clone(), root_control.clone()).unwrap();
				owner.initialize().await.unwrap();
				let (target, _target_control) = environment::restore(&attachment, operator).await;
				owner.import(case.coordinate(1), target.clone(), None).await.unwrap();
				let mut revocation_peer = None;
				let mut revocation_import = None;
				if case.name == "revokeManagedRoomAuthority" {
					let coordinate = custody::Coordinate {
						role: custody::Role::RoomAccess,
						key: case.coordinate(3).key,
					};
					// A foreign application publication carries a saved URI. A Loam
					// local recipe has no transport locator to export.
					let exporter = Host::from_seed([113; 32]).unwrap();
					let locator = glowcap::Locator::bare("tcp", "127.0.0.1:9011");
					exporter.set_advertised_locator(&locator).unwrap();
					*revoked.borrow_mut() = Some(
						exporter
							.publish_durable_with_entropy([33; 16], || Box::new(|_, _| Err("not invoked".into())))
							.unwrap(),
					);
					let (dialed, accepted) = results::connect(&host, &exporter, &locator, gate::Gate::default()).await;
					let uri = glowcap::format_sturdyref(
						&locator,
						revoked.borrow().as_ref().unwrap().as_bytes(),
						glowcap::CaptpVersion::V1_0,
					)
					.unwrap();
					let public = host.enliven(&uri).await.unwrap();
					revocation_import = Some((coordinate, public.clone(), uri.clone()));
					owner.import(coordinate, public, Some(uri)).await.unwrap();
					revocation_peer = Some((exporter, dialed, accepted));
				}
				if case.role == custody::Role::RoomAccess {
					// Room entry holds different actual authority from moderation.
					// Selecting entry would invoke the replacement payload and fail.
					let (entry, _) = environment::restore(&attachment, replacement).await;
					owner.import(case.coordinate(3), entry, None).await.unwrap();
				}
				if case.role != custody::Role::Operator {
					owner
						.import(
							custody::Coordinate {
								role: custody::Role::DirectoryAccess,
								key: key(),
							},
							target,
							None,
						)
						.await
						.unwrap();
				}
				let intent = case.workspace(1);
				owner.replace_workspace(&intent).await.unwrap();
				let permissions: Vec<_> = session::SUPPORTED.iter().map(|p| p.key()).collect();
				let terms = policy.value_for_kind(session::KIND, &permissions, &[]).unwrap();
				let powers = ControlPowers {
					policy_ceiling: Some(terms),
					pause: true,
					resume: true,
					revoke: true,
					..Default::default()
				};
				let (source, control) = owner.derive(terms, 1, powers).await.unwrap();
				let (other, _other_control) = owner.derive(terms, 1, powers).await.unwrap();
				let snapshot = host.send(&source, "snapshot", &[]).await.unwrap();
				let base = snapshot.as_list().unwrap()[0].clone();
				let mut args = vec!["effect-one".into(), base, case.name.into()];
				args.extend(case.args.iter().cloned().map(Argument::String));
				let canonical =
					serde_json::to_string(&("effect-one", args[1].as_i64().unwrap(), case.name, &case.args)).unwrap();
				platform.suspended.set(true);
				assert_eq!(
					mutate(&host, &source, "command", &args).await.unwrap().as_str(),
					Some("pending")
				);
				let (replacement, _) = environment::restore(&attachment, replacement).await;
				owner.import(case.coordinate(2), replacement, None).await.unwrap();
				owner.replace_workspace(&case.workspace(2)).await.unwrap();
				platform.tasks.borrow().last().unwrap().abort();
				for _ in 0..3 {
					tokio::task::yield_now().await;
				}
				assert_eq!(
					calls.get(),
					0,
					"cancellation before the first worker poll cannot dispatch"
				);
				assert_eq!(
					finished(&host, &other, "effect-one", &source).await.as_str(),
					Some("unknown")
				);
				platform.observation_suspended.set(true);
				platform.suspended.set(false);
				recovery::resume(&host, &source, &other, &canonical).await;
				while calls.get() == 0 {
					host.send(
						&other,
						"effect-status",
						&["effect-one".into(), Argument::Reference(source.clone())],
					)
					.await
					.unwrap();
					environment::yield_turn().await;
				}
				host.send(
					&control,
					"pause",
					&[Argument::Bytes(
						glowcap::loam::control_revision(&host, &control)
							.await
							.unwrap()
							.to_be_bytes()
							.to_vec(),
					)],
				)
				.await
				.unwrap();
				platform.tasks.borrow().last().unwrap().abort();
				for _ in 0..3 {
					tokio::task::yield_now().await;
				}
				assert_eq!(calls.get(), 1, "upstream application precedes interrupted observation");
				assert_eq!(
					finished(&host, &other, "effect-one", &source).await.as_str(),
					Some("unknown")
				);
				refuse_settlement.set(true);
				platform.observation_suspended.set(false);
				owner.resume_pending().unwrap();
				assert_eq!(
					finished(&host, &other, "effect-one", &source).await.as_str(),
					Some("unknown")
				);
				refuse_settlement.set(false);
				owner.resume_pending().unwrap();

				let observed = finished(&host, &other, "effect-one", &source).await;
				if observed.as_str() != Some("committed") {
					panic!("receipt status {observed:?}; owner close {:?}", owner.close().await);
				}
				host.send(
					&control,
					"resume",
					&[Argument::Bytes(
						glowcap::loam::control_revision(&host, &control)
							.await
							.unwrap()
							.to_be_bytes()
							.to_vec(),
					)],
				)
				.await
				.unwrap();
				assert_eq!(calls.get(), 1);
				assert!(
					host.send(
						&other,
						"effect-status",
						&["effect-one".into(), Argument::Reference(other.clone())]
					)
					.await
					.is_err()
				);
				assert!(
					host.send(
						&other,
						"effect-result",
						&["effect-one".into(), canonical.clone().into()]
					)
					.await
					.is_err(),
					"equal masks do not replace actual source"
				);
				assert_eq!(
					host.send(
						&source,
						"effect-result",
						&["effect-one".into(), canonical.clone().into()]
					)
					.await
					.unwrap()
					.as_str(),
					Some(case.retained_result())
				);
				assert_eq!(
					mutate(&host, &source, "command", &args).await.unwrap().as_str(),
					Some("committed")
				);
				assert_eq!(
					calls.get(),
					1,
					"application retry joins receipt without re-executing target"
				);
				host.send(
					&control,
					"pause",
					&[Argument::Bytes(
						glowcap::loam::control_revision(&host, &control)
							.await
							.unwrap()
							.to_be_bytes()
							.to_vec(),
					)],
				)
				.await
				.unwrap();
				assert!(
					host.send(
						&source,
						"effect-result",
						&["effect-one".into(), canonical.clone().into()]
					)
					.await
					.is_err()
				);
				host.send(
					&control,
					"resume",
					&[Argument::Bytes(
						glowcap::loam::control_revision(&host, &control)
							.await
							.unwrap()
							.to_be_bytes()
							.to_vec(),
					)],
				)
				.await
				.unwrap();
				assert_eq!(
					host.send(
						&source,
						"effect-result",
						&["effect-one".into(), canonical.clone().into()]
					)
					.await
					.unwrap()
					.as_str(),
					Some(case.retained_result())
				);
				host.send(
					&control,
					"revoke",
					&[Argument::Bytes(
						glowcap::loam::control_revision(&host, &control)
							.await
							.unwrap()
							.to_be_bytes()
							.to_vec(),
					)],
				)
				.await
				.unwrap();
				assert!(
					host.send(&source, "effect-result", &["effect-one".into(), canonical.into()])
						.await
						.is_err()
				);
				assert_eq!(
					finished(&host, &other, "effect-one", &source).await.as_str(),
					Some("committed"),
					"recovery status does not disclose a revoked source result"
				);
				if let Some((coordinate, authority, uri)) = &revocation_import {
					// A new gesture needs an explicit authority acquisition. Receipt
					// replay above observes the original occurrence without restoring it.
					owner
						.import(*coordinate, authority.clone(), Some(uri.clone()))
						.await
						.unwrap();
				}
				owner.replace_workspace(&intent).await.unwrap();
				let snapshot = host.send(&root, "snapshot", &[]).await.unwrap();
				let mut cold_args = args.clone();
				cold_args[0] = "effect-cold".into();
				cold_args[1] = snapshot.as_list().unwrap()[0].clone();
				let mut committed_args = cold_args.clone();
				committed_args[0] = "effect-root".into();
				mutate(&host, &root, "command", &committed_args).await.unwrap();
				assert_eq!(
					finished(&host, &root, "effect-root", &root).await.as_str(),
					Some("committed")
				);
				if let Some((coordinate, authority, uri)) = &revocation_import {
					owner
						.import(*coordinate, authority.clone(), Some(uri.clone()))
						.await
						.unwrap();
					owner.replace_workspace(&intent).await.unwrap();
				}
				let snapshot = host.send(&root, "snapshot", &[]).await.unwrap();
				cold_args[1] = snapshot.as_list().unwrap()[0].clone();
				malformed.set(true);
				assert_eq!(
					mutate(&host, &root, "command", &cold_args).await.unwrap().as_str(),
					Some("pending")
				);
				assert_eq!(
					finished(&host, &root, "effect-cold", &root).await.as_str(),
					Some("unknown")
				);
				assert_eq!(calls.get(), 3);
				let snapshot = host.send(&root, "snapshot", &[]).await.unwrap();
				let mut aborted_args = cold_args.clone();
				aborted_args[0] = "effect-abort".into();
				aborted_args[1] = snapshot.as_list().unwrap()[0].clone();
				refuse.set(true);
				assert!(mutate(&host, &root, "command", &aborted_args).await.is_err());
				refuse.set(false);
				let after = host.send(&root, "snapshot", &[]).await.unwrap();
				assert_eq!(
					after.as_list().unwrap()[0].as_i64(),
					snapshot.as_list().unwrap()[0].as_i64(),
					"callback refusal commits no content revision"
				);
				let empty_intent = serde_json::to_string(&Intent::empty()).unwrap();
				let coordinate = serde_json::to_string(&case.coordinate(1)).unwrap();
				// Revoke the upstream use before releasing local custody. The
				// unresolved receipt independently retains the original target.
				host.send(
					&_target_control,
					"revoke",
					&[Argument::Bytes(
						glowcap::loam::control_revision(&host, &_target_control)
							.await
							.unwrap()
							.to_be_bytes()
							.to_vec(),
					)],
				)
				.await
				.unwrap();
				if matches!(
					case.role,
					custody::Role::Operator | custody::Role::Operations | custody::Role::IrcConnection
				) {
					mutate(&host, &root, "release", &[coordinate.into(), empty_intent.into()])
						.await
						.unwrap();
				} else {
					let snapshot = host.send(&root, "snapshot", &[]).await.unwrap();
					let departure = [
						"departure".into(),
						snapshot.as_list().unwrap()[0].clone(),
						"leaveDirectory".into(),
						"directory".into(),
					];
					assert_eq!(
						mutate(&host, &root, "command", &departure).await.unwrap().as_str(),
						Some("committed")
					);
					assert!(
						mutate(&host, &root, "release", &[coordinate.into(), empty_intent.into()])
							.await
							.is_err(),
						"departure released the selected field without restoring revoked authority"
					);
				}
				owner.close().await.unwrap();
				assert_eq!(
					calls.get(),
					3,
					"confirmed receipt absence retires its worker without dispatch"
				);
				assert!(
					host.send(
						&root,
						"effect-status",
						&["effect-abort".into(), Argument::Reference(root.clone())]
					)
					.await
					.is_err()
				);
				let live_marker = if case.role.live() {
					Some(attachment.live_marker().unwrap().unwrap())
				} else {
					None
				};
				attachment.close().await.unwrap();
				host.close(PendingWork::Cancel).await.unwrap();
				if let Some((exporter, dialed, accepted)) = revocation_peer.take() {
					dialed.close(PendingWork::Cancel).await.unwrap();
					accepted.close(PendingWork::Cancel).await.unwrap();
					exporter.close(PendingWork::Cancel).await.unwrap();
				}
				drop(owner);
				environment::close(&mut store).await;
				drop(store);
				let mut reopened = database.open(false, &schemas, limits).await;
				let cold_host = Host::from_seed([112; 32]).unwrap();
				cold_host
					.set_advertised_locator(&glowcap::Locator::bare("tcp", "127.0.0.1:9012"))
					.unwrap();
				let cold_owner = managed::Session::new(
					cold_host.clone(),
					Platform::default(),
					std::num::NonZeroUsize::new(4096).unwrap(),
				);
				let cold_calls = Rc::new(Cell::new(0));
				let mut cold_attachment = reopened
					.attach(
						&cold_host,
						vec![
							cold_owner.registration(),
							target_registration_with_token(
								cold_calls.clone(),
								Rc::new(Cell::new(false)),
								&case,
								revoked.clone(),
							),
						],
					)
					.unwrap();
				if case.role.live() {
					cold_attachment.start_live(live_marker, 32).unwrap();
				}
				let (cold_root, cold_root_control) =
					environment::restore(&cold_attachment, loam::Resource::decode(resource.encode())).await;
				cold_owner.bind(cold_root.clone(), cold_root_control.clone()).unwrap();
				let canonical = serde_json::to_string(&(
					"effect-root",
					committed_args[1].as_i64().unwrap(),
					case.name,
					&case.args,
				))
				.unwrap();
				assert_eq!(
					cold_host
						.send(&cold_root, "effect-result", &["effect-root".into(), canonical.into()])
						.await
						.unwrap()
						.as_str(),
					Some(case.retained_result()),
					"committed typed data survives cold restoration after target revocation"
				);
				assert_eq!(
					finished(&cold_host, &cold_root, "effect-cold", &cold_root)
						.await
						.as_str(),
					Some("unknown")
				);
				assert_eq!(
					mutate(&cold_host, &cold_root, "command", &cold_args)
						.await
						.unwrap()
						.as_str(),
					Some("unknown")
				);
				assert_eq!(
					cold_calls.get(),
					0,
					"cold unresolved receipts cannot justify redispatch"
				);
				recovery::cold(
					&cold_host,
					&cold_root,
					case.retained_result(),
					&cold_calls,
					!matches!(
						case.role,
						custody::Role::Operator | custody::Role::Operations | custody::Role::IrcConnection
					),
				)
				.await;
				cold_owner.close().await.unwrap();
				cold_attachment.close().await.unwrap();
				cold_host.close(PendingWork::Cancel).await.unwrap();
				drop(cold_owner);
				environment::close(&mut reopened).await;
				drop(reopened);
				database.remove();
			})
			.await
			.expect("production receipt owner has bounded progress");
		})
		.await;
}
