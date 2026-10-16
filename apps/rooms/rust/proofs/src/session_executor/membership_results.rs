//! The production executor retains subscription inputs and every returned facet.
use super::*;
use rooms_application::{content::permissions::Permission, content::session::results::Membership};

mod upstream;
pub(super) use upstream::{MEMBER, registration, registration_with_retirement};
fn coordinate(role: custody::Role, slot: u64) -> custody::Coordinate {
	custody::Coordinate {
		role,
		key: custody::FieldKey::new(NonZeroU64::new(slot).unwrap(), NonZeroU64::new(1).unwrap()),
	}
}
pub(super) async fn command(host: &Host, source: &Ref, id: &str, callback: u64) -> (Vec<Argument>, String) {
	let snapshot = host.send(source, "snapshot", &[]).await.unwrap();
	let base = snapshot.as_list().unwrap()[0].as_i64().unwrap();
	let callback = serde_json::to_string(&coordinate(custody::Role::RoomInbox, callback).key).unwrap();
	let rest = ["conversation", "member", callback.as_str()];
	let canonical = serde_json::to_string(&(id, base, "joinRoom", rest)).unwrap();
	let mut args = vec![id.into(), base.into(), "joinRoom".into()];
	args.extend(rest.into_iter().map(Argument::from));
	(args, canonical)
}
pub(super) async fn disclose(host: &Host, source: &Ref, id: &str, canonical: &str) -> (String, Vec<Ref>) {
	let answer = host
		.send(source, "effect-result", &[id.into(), canonical.into()])
		.await
		.unwrap();
	let [data, fields] = answer.as_list().unwrap() else {
		panic!("typed membership result")
	};
	let row: Membership = serde_json::from_str(data.as_str().unwrap()).unwrap();
	let mut expected = vec![coordinate(custody::Role::RoomSeat, 1)];
	if row.subject.is_some() {
		expected.push(coordinate(custody::Role::RoomSubject, 1));
	}
	if row.files.is_some() {
		expected.push(coordinate(custody::Role::RoomFiles, 1));
	}
	assert_eq!(row.kind, rooms_application::room::policy::MembershipKind::Participant);
	assert_eq!(row.seat, key());
	let actual = fields.as_list().unwrap();
	assert_eq!(actual.len(), expected.len());
	let references = actual
		.iter()
		.zip(expected)
		.map(|(field, expected)| {
			let [coordinate, reference] = field.as_list().unwrap() else {
				panic!("exact result field")
			};
			assert_eq!(
				serde_json::from_str::<custody::Coordinate>(coordinate.as_str().unwrap()).unwrap(),
				expected
			);
			Ref::try_from(reference).unwrap()
		})
		.collect();
	(data.as_str().unwrap().into(), references)
}

#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn subscription_retains_original_inputs_and_stable_optional_results_across_interruption_and_restart() {
	run().await;
}
pub(super) async fn run() {
	for options in 0..4 {
		run_case(options).await;
	}
}
async fn post(host: &Host, root: &Ref, id: &str, committed: bool) {
	let snapshot = host.send(root, "snapshot", &[]).await.unwrap();
	let args = [
		id.into(),
		snapshot.as_list().unwrap()[0].clone(),
		"say".into(),
		"conversation".into(),
		"posted through imported seat".into(),
	];
	if mutate(host, root, "command", &args).await.is_ok() {
		assert_eq!(
			finished(host, root, id, root).await.as_str() == Some("committed"),
			committed
		);
	} else {
		assert!(!committed);
	}
}
async fn run_case(options: u8) {
	tokio::task::LocalSet::new()
		.run_until(async {
			environment::within(10_000, async {
				let database = Database::new(&format!("membership-{options}"));
				let mut schemas = managed::schemas();
				schemas.push(MEMBER);
				let mut limits = crate::session_storage::limits_for(
					24,
					8,
					loam::ValueBounds {
						values: 48,
						capabilities: 12,
						bytes: 4096,
						..Default::default()
					},
				);
				limits.pending_bytes = limits.call_bytes * limits.max_operations;
				limits.ingress_bytes = limits.pending_bytes;
				limits.max_leases *= limits.max_operations;
				// Two endpoints for the session, six upstream resources and two
				// independently derived sources exercised by result import.
				limits.max_references = 2 * (1 + 6 + 2);
				limits.max_retentions = 24 + limits.max_references;
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
				let mut resources = Vec::new();
				for payload in [
					b"entrance".as_slice(),
					b"seat",
					b"subject",
					b"files",
					b"inbox",
					b"replacement",
				] {
					resources.push(environment::create(&store, &policy, MEMBER, payload, 2).await);
				}
				let host = Host::from_seed([119; 32]).unwrap();
				let platform = Platform::default();
				let owner = managed::Session::new(
					host.clone(),
					platform.clone(),
					std::num::NonZeroUsize::new(4096).unwrap(),
				);
				let joins = Rc::new(Cell::new(0));
				let acts = Rc::new(Cell::new(0));
				let notices = Rc::new(Cell::new(0));
				let refuse = Rc::new(Cell::new(true));
				let refuse_import = Rc::new(Cell::new(false));
				let mut content = owner.registration();
				content.content = Box::new(AbortAfterAdmission {
					inner: content.content,
					refuse: refuse_import.clone(),
					refuse_settlement: refuse.clone(),
				});
				let mut attachment = store
					.attach(
						&host,
						vec![
							content,
							registration(joins.clone(), acts.clone(), notices.clone(), options),
						],
					)
					.unwrap();
				attachment.start_live(None, 64).unwrap();
				let (root, root_control) = environment::restore(&attachment, resource).await;
				owner.bind(root.clone(), root_control.clone()).unwrap();
				owner.initialize().await.unwrap();
				let mut held = Vec::new();
				let mut controls = Vec::new();
				for resource in resources {
					let (access, control) = environment::restore(&attachment, resource).await;
					held.push(access);
					controls.push(control);
				}
				host.send(
					&held[0],
					"configure",
					&held[1..4].iter().cloned().map(Argument::Reference).collect::<Vec<_>>(),
				)
				.await
				.unwrap();
				for (role, slot, reference) in [
					(custody::Role::RoomAccess, 1, &held[0]),
					(custody::Role::RoomAccess, 2, &held[5]),
					(custody::Role::DirectoryAccess, 1, &held[0]),
					(custody::Role::RoomInbox, 1, &held[4]),
				] {
					owner
						.import(coordinate(role, slot), reference.clone(), None)
						.await
						.unwrap();
				}
				let mut intent = Case::kick().workspace(1);
				let session::workspace::Conversation::Room(room) = &mut intent.conversations.as_mut_slice()[0] else {
					panic!("room")
				};
				room.moderator = None;
				room.access = Some(key());
				room.inbox = Some(key());
				owner.replace_workspace(&intent).await.unwrap();
				let terms = policy
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
							policy_ceiling: Some(terms),
							pause: true,
							resume: true,
							revoke: true,
							..Default::default()
						},
					)
					.await
					.unwrap();
				let (missing, _) = command(&host, &source, "missing", 2).await;
				assert!(mutate(&host, &source, "command", &missing).await.is_err());
				assert_eq!(joins.get(), 0);
				platform.suspended.set(true);
				let (args, canonical) = command(&host, &source, "joined", 1).await;
				assert_eq!(
					mutate(&host, &source, "command", &args).await.unwrap().as_str(),
					Some("pending")
				);
				assert_eq!(joins.get(), 0);
				let session::workspace::Conversation::Room(room) = &mut intent.conversations.as_mut_slice()[0] else {
					panic!("room")
				};
				room.access = Some(custody::FieldKey::new(
					NonZeroU64::new(2).unwrap(),
					NonZeroU64::new(1).unwrap(),
				));
				room.inbox = None;
				owner.replace_workspace(&intent).await.unwrap();
				let replacement = serde_json::to_string(&intent).unwrap();
				mutate(
					&host,
					&root,
					"release",
					&[
						serde_json::to_string(&coordinate(custody::Role::RoomInbox, 1))
							.unwrap()
							.into(),
						replacement.into(),
					],
				)
				.await
				.unwrap();
				platform.suspended.set(false);
				assert_eq!(
					finished(&host, &root, "joined", &source).await.as_str(),
					Some("unknown")
				);
				assert_eq!(joins.get(), 1);
				let callback = Ref::try_from(&host.send(&held[0], "inbox", &[]).await.unwrap()).unwrap();
				assert_ne!(callback, held[4], "upstream receives a source-guarded callback");
				host.send(&callback, "notify", &[]).await.unwrap();
				assert_eq!(notices.get(), 1);
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
				assert!(host.send(&callback, "notify", &[]).await.is_err());
				assert_eq!(notices.get(), 1);
				refuse.set(false);
				owner.resume_pending().unwrap();
				assert_eq!(
					finished(&host, &root, "joined", &source).await.as_str(),
					Some("committed")
				);
				assert!(
					host.send(&source, "effect-result", &["joined".into(), canonical.clone().into()])
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
				let (data, actual) = disclose(&host, &source, "joined", &canonical).await;
				assert_eq!(disclose(&host, &source, "joined", &canonical).await.1, actual);
				assert_ne!(actual[0], held[1]);
				if options & 2 != 0 {
					assert!(
						host.send(actual.last().unwrap(), "attach", &[]).await.is_err(),
						"capability-returning file methods require recursive result mediation"
					);
				}
				host.send(&actual[0], "typing", &[true.into()]).await.unwrap();
				assert_eq!(acts.get(), 1);
				host.send(
					&controls[1],
					"pause",
					&[Argument::Bytes(
						glowcap::loam::control_revision(&host, &controls[1])
							.await
							.unwrap()
							.to_be_bytes()
							.to_vec(),
					)],
				)
				.await
				.unwrap();
				assert!(host.send(&actual[0], "typing", &[true.into()]).await.is_err());
				assert_eq!(acts.get(), 1);
				host.send(
					&controls[1],
					"resume",
					&[Argument::Bytes(
						glowcap::loam::control_revision(&host, &controls[1])
							.await
							.unwrap()
							.to_be_bytes()
							.to_vec(),
					)],
				)
				.await
				.unwrap();
				if options & 1 != 0 {
					host.send(&actual[1], "setSubject", &["subject".into()]).await.unwrap();
				}
				let observation = policy
					.value_for_kind(session::KIND, &[Permission::ObserveWorkspace.key()], &[])
					.unwrap();
				host.send(
					&control,
					"mutate",
					&observation
						.set_policy_arguments(1, glowcap::loam::control_revision(&host, &control).await.unwrap()),
				)
				.await
				.unwrap();
				let count = acts.get();
				assert!(host.send(&actual[0], "typing", &[true.into()]).await.is_err());
				assert_eq!(acts.get(), count);
				host.send(&callback, "notify", &[]).await.unwrap();
				assert_eq!(notices.get(), 2);
				host.send(
					&control,
					"mutate",
					&terms.set_policy_arguments(2, glowcap::loam::control_revision(&host, &control).await.unwrap()),
				)
				.await
				.unwrap();
				let result_fields = [
					(custody::Role::RoomSeat, &held[1]),
					(custody::Role::RoomSubject, &held[2]),
					(custody::Role::RoomFiles, &held[3]),
				]
				.into_iter()
				.enumerate()
				.filter(|(index, _)| *index == 0 || options & (1 << (*index - 1)) != 0)
				.map(|(_, (role, reference))| {
					Argument::List(vec![
						serde_json::to_string(&coordinate(role, 1)).unwrap().into(),
						Argument::Reference(reference.clone()),
						Argument::List(vec!["live".into()]),
					])
				})
				.collect::<Vec<_>>();
				let settle = |fields: Vec<Argument>| {
					[
						"joined".into(),
						Argument::Reference(source.clone()),
						canonical.clone().into(),
						Argument::List(vec![data.clone().into(), Argument::List(fields)]),
						Argument::Void,
					]
				};
				host.send(&root, "settle-effect", &settle(result_fields.clone()))
					.await
					.unwrap();
				assert_eq!(disclose(&host, &source, "joined", &canonical).await.1, actual);
				let mut substituted = result_fields.clone();
				if let Argument::List(field) = &mut substituted[0] {
					field[1] = Argument::Reference(held[5].clone());
				}
				assert!(host.send(&root, "settle-effect", &settle(substituted)).await.is_err());
				assert!(host.send(&root, "settle-effect", &settle(Vec::new())).await.is_err());
				result_imports::membership(
					&host,
					&owner,
					(&root, &source, &control),
					(&policy, terms),
					&canonical,
					&actual,
					(&refuse_import, &held[5]),
				)
				.await;
				assert_eq!(joins.get(), 1);
				// Select the transferred seat, then post through the independent
				// private root. The imported facet still checks its original source.
				let session::workspace::Conversation::Room(room) = &mut intent.conversations.as_mut_slice()[0] else {
					panic!("room");
				};
				room.seat = Some(custody::FieldKey::new(
					NonZeroU64::new(7).unwrap(),
					NonZeroU64::new(1).unwrap(),
				));
				owner.replace_workspace(&intent).await.unwrap();
				let before = acts.get();
				post(&host, &root, "imported-post", true).await;
				assert_eq!(acts.get(), before + 1);
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
				assert!(host.send(&callback, "notify", &[]).await.is_err());
				assert_eq!(notices.get(), 2);
				assert!(host.send(&actual[0], "typing", &[true.into()]).await.is_err());
				let before = acts.get();
				post(&host, &root, "revoked-post", false).await;
				assert_eq!(
					acts.get(),
					before,
					"private root cannot bypass imported seat revocation"
				);
				// A root-owned receipt remains inspectable after physical reopening;
				// its exact live inputs and result authority cannot survive the marker.
				owner
					.import(coordinate(custody::Role::RoomInbox, 1), held[4].clone(), None)
					.await
					.unwrap();
				let session::workspace::Conversation::Room(room) = &mut intent.conversations.as_mut_slice()[0] else {
					panic!("room")
				};
				room.access = Some(key());
				room.inbox = Some(key());
				owner.replace_workspace(&intent).await.unwrap();
				let (root_args, root_canonical) = command(&host, &root, "joined-root", 1).await;
				mutate(&host, &root, "command", &root_args).await.unwrap();
				assert_eq!(
					finished(&host, &root, "joined-root", &root).await.as_str(),
					Some("committed")
				);
				assert_eq!(joins.get(), 2);
				let marker = attachment.live_marker().unwrap().unwrap();
				owner.close().await.unwrap();
				attachment.close().await.unwrap();
				host.close(PendingWork::Cancel).await.unwrap();
				drop(owner);
				environment::close(&mut store).await;
				drop(store);
				let mut reopened = database.open(false, &schemas, limits).await;
				let cold_host = Host::from_seed([119; 32]).unwrap();
				let cold_owner = managed::Session::new(
					cold_host.clone(),
					Platform::default(),
					std::num::NonZeroUsize::new(4096).unwrap(),
				);
				let mut cold_attachment = reopened.attach(&cold_host, vec![cold_owner.registration()]).unwrap();
				cold_attachment.start_live(Some(marker), 64).unwrap();
				let (cold_root, cold_root_control) =
					environment::restore(&cold_attachment, loam::Resource::decode(resource.encode())).await;
				cold_owner.bind(cold_root.clone(), cold_root_control.clone()).unwrap();
				let error = cold_host
					.send(
						&cold_root,
						"effect-result",
						&["joined-root".into(), root_canonical.clone().into()],
					)
					.await
					.unwrap_err();
				assert_eq!(error.message(), Some("LiveReferenceExpired"));
				let before = cold_host.send(&cold_root, "snapshot", &[]).await.unwrap();
				assert!(
					cold_owner
						.import_result(
							&cold_root,
							"joined-root",
							&root_canonical,
							coordinate(custody::Role::RoomSeat, 1),
							coordinate(custody::Role::RoomSeat, 9),
						)
						.await
						.is_err(),
					"result import cannot revive an expired facet"
				);
				assert_eq!(cold_host.send(&cold_root, "snapshot", &[]).await.unwrap(), before);
				assert_eq!(
					finished(&cold_host, &cold_root, "joined-root", &cold_root)
						.await
						.as_str(),
					Some("committed")
				);
				let (fresh, _) = command(&cold_host, &cold_root, "fresh", 1).await;
				assert!(
					mutate(&cold_host, &cold_root, "command", &fresh).await.is_err(),
					"expired callback cannot be reconstructed"
				);
				cold_owner.close().await.unwrap();
				cold_attachment.close().await.unwrap();
				cold_host.close(PendingWork::Cancel).await.unwrap();
				drop(cold_owner);
				environment::close(&mut reopened).await;
				drop(reopened);
				database.remove();
			})
			.await
			.expect("membership custody has bounded progress");
		})
		.await;
}
