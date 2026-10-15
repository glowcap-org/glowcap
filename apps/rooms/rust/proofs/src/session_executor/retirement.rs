//! Exact upstream retirement and local alias removal share one receipt commit.
//! Refusal preserves selection. Committed retirement cannot redirect recovery.
use super::*;
use rooms_application::{content::permissions::Permission, content::session::workspace};

async fn snapshot(host: &Host, source: &Ref) -> (Argument, Intent) {
	let value = host.send(source, "snapshot", &[]).await.unwrap();
	let [base, intent] = value.as_list().unwrap() else {
		panic!("snapshot");
	};
	(base.clone(), Intent::decode(intent.as_str().unwrap()).unwrap())
}
fn coordinate(role: custody::Role, generation: u64) -> custody::Coordinate {
	custody::Coordinate {
		role,
		key: custody::FieldKey::new(NonZeroU64::new(1).unwrap(), NonZeroU64::new(generation).unwrap()),
	}
}
#[derive(Clone, Copy)]
enum Scenario {
	Membership,
	Publication,
}
impl Scenario {
	fn name(self) -> &'static str {
		match self {
			Self::Membership => "retireRoomMembership",
			Self::Publication => "revokePeeredRoom",
		}
	}
	fn id(self) -> &'static str {
		match self {
			Self::Membership => "conversation",
			Self::Publication => "publication",
		}
	}
	fn role(self) -> custody::Role {
		match self {
			Self::Membership => custody::Role::RoomSeat,
			Self::Publication => custody::Role::PublicationLease,
		}
	}
	fn verb(self) -> &'static str {
		match self {
			Self::Membership => "leave",
			Self::Publication => "revoke",
		}
	}
	fn publication(self, generation: u64) -> workspace::Peering {
		workspace::Peering {
			id: rooms_application::fields::Text::new(self.id().into()).unwrap(),
			directory: rooms_application::fields::Text::new("directory".into()).unwrap(),
			room: key(),
			lease: custody::FieldKey::new(NonZeroU64::new(1).unwrap(), NonZeroU64::new(generation).unwrap()),
			name: rooms_application::fields::Text::new("room".into()).unwrap(),
		}
	}
	fn retired(self, intent: &Intent) {
		if matches!(self, Self::Publication) {
			assert!(intent.peering.is_empty());
			for row in intent.conversations.as_slice() {
				let workspace::Conversation::Room(room) = row else {
					panic!("room");
				};
				assert_eq!(room.access, Some(key()));
				assert_eq!(
					room.seat,
					Some(key()),
					"publication revocation keeps independent membership"
				);
			}
		} else {
			retired(intent);
		}
	}
}
fn command(scenario: Scenario, id: &str, base: Argument, generation: u64) -> Vec<Argument> {
	vec![
		id.into(),
		base,
		scenario.name().into(),
		scenario.id().into(),
		serde_json::to_string(&coordinate(scenario.role(), generation).key)
			.unwrap()
			.into(),
	]
}
fn retired(intent: &Intent) {
	for row in intent.conversations.as_slice() {
		let workspace::Conversation::Room(room) = row else {
			panic!("room");
		};
		assert!(room.seat.is_none() && room.topic.is_none() && room.lines.is_empty());
		assert_eq!(room.reconnect, workspace::Reconnect::Manual);
	}
}

#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn membership_retirement_commits_exact_goodbye_clears_aliases_and_never_retargets_recovery() {
	run_scenario(Scenario::Membership).await;
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn publication_retirement_commits_exact_revoke_clears_aliases_and_never_retargets_recovery() {
	run_scenario(Scenario::Publication).await;
}
#[cfg(target_arch = "wasm32")]
pub(super) async fn run() {
	for scenario in [Scenario::Membership, Scenario::Publication] {
		run_scenario(scenario).await;
	}
}
async fn run_scenario(scenario: Scenario) {
	for mode in ["committed", "source-paused", "target-revoked", "malformed"] {
		run_case(scenario, mode).await;
	}
}
async fn run_case(scenario: Scenario, mode: &str) {
	tokio::task::LocalSet::new()
		.run_until(async {
			environment::within(10_000, async {
				let database = Database::new(&format!("{}-{mode}", scenario.name()));
				let mut schemas = managed::schemas();
				schemas.push(TARGET);
				let mut limits = crate::session_storage::limits_for(
					24,
					8,
					loam::ValueBounds {
						values: 32,
						capabilities: 4,
						bytes: 8192,
						..Default::default()
					},
				);
				limits.pending_bytes = limits.call_bytes * limits.max_operations;
				limits.ingress_bytes = limits.pending_bytes;
				limits.max_leases *= limits.max_operations;
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
				let original = environment::create(&store, &policy, TARGET, b"original", 1).await;
				let replacement = environment::create(&store, &policy, TARGET, b"replacement", 1).await;
				let host = Host::from_seed([123; 32]).unwrap();
				let platform = Platform::default();
				let owner = managed::Session::new(
					host.clone(),
					platform.clone(),
					std::num::NonZeroUsize::new(8192).unwrap(),
				);
				let refuse = Rc::new(Cell::new(false));
				let refuse_settlement = Rc::new(Cell::new(false));
				let calls = Rc::new(Cell::new(0));
				let malformed = Rc::new(Cell::new(mode == "malformed"));
				let case = Case {
					name: scenario.name(),
					args: vec![],
					verb: scenario.verb(),
					forwarded: vec![],
					role: scenario.role(),
					policy: None,
				};
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
							target_registration(calls.clone(), malformed.clone(), &case),
						],
					)
					.unwrap();
				attachment.start_live(None, 32).unwrap();
				let (root, root_control) = environment::restore(&attachment, resource).await;
				owner.bind(root.clone(), root_control.clone()).unwrap();
				owner.initialize().await.unwrap();
				let (target, target_control) = environment::restore(&attachment, original).await;
				for role in [
					custody::Role::DirectoryAccess,
					custody::Role::RoomSeat,
					custody::Role::RoomTopic,
					custody::Role::Line,
				] {
					owner.import(coordinate(role, 1), target.clone(), None).await.unwrap();
				}
				let mut intent = Case::away().workspace(1);
				if matches!(scenario, Scenario::Publication) {
					for role in [custody::Role::RoomAccess, custody::Role::PublicationLease] {
						owner.import(coordinate(role, 1), target.clone(), None).await.unwrap();
					}
					let publication = scenario.publication(1);
					let mut alias = publication.clone();
					alias.id = rooms_application::fields::Text::new("publication-alias".into()).unwrap();
					intent.peering = List::new(vec![publication, alias]).unwrap();
				}
				let workspace::Conversation::Room(room) = &mut intent.conversations.as_mut_slice()[0] else {
					panic!("room");
				};
				room.topic = Some(key());
				if matches!(scenario, Scenario::Publication) {
					room.access = Some(key());
				}
				room.lines =
					serde_json::from_value(serde_json::json!([{ "id": 23, "handle": key::<custody::Line>() }]))
						.unwrap();
				let mut alias = room.clone();
				alias.id = rooms_application::fields::Text::new("alias".into()).unwrap();
				intent
					.conversations
					.try_push(workspace::Conversation::Room(alias))
					.unwrap();
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
				let sequence = host
					.send(&root, "derivation-sequence", &[])
					.await
					.unwrap()
					.as_i64()
					.unwrap() as u32;
				let (source, control) = owner.derive(terms, 1, powers).await.unwrap();
				let (other, _) = owner.derive(terms, 1, powers).await.unwrap();
				let observer_terms = policy
					.value_for_kind(session::KIND, &[Permission::ObserveWorkspace.key()], &[])
					.unwrap();
				let (observer, _) = owner.derive(observer_terms, 1, ControlPowers::default()).await.unwrap();
				let (base, before) = snapshot(&host, &source).await;
				let args = command(scenario, "retired", base.clone(), 1);
				assert!(mutate(&host, &observer, "command", &args).await.is_err());
				assert!(
					mutate(&host, &source, "command", &command(scenario, "stale", base.clone(), 2))
						.await
						.is_err()
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
				assert!(mutate(&host, &source, "command", &args).await.is_err());
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
				refuse.set(true);
				assert!(
					mutate(
						&host,
						&source,
						"command",
						&command(scenario, "refused", base.clone(), 1)
					)
					.await
					.is_err()
				);
				refuse.set(false);
				assert_eq!(snapshot(&host, &source).await, (base, before));
				assert_eq!(calls.get(), 0, "receipt rollback cannot dispatch retirement");
				platform.suspended.set(true);
				assert_eq!(
					mutate(&host, &source, "command", &args).await.unwrap().as_str(),
					Some("pending")
				);
				let (_, mut replacement_intent) = snapshot(&host, &source).await;
				scenario.retired(&replacement_intent);
				assert_eq!(calls.get(), 0, "local retirement commits before worker polling");
				// Reuse the same slot with a different generation and actual target.
				// The saved receipt still owns the original target independently.
				let (replacement, _) = environment::restore(&attachment, replacement).await;
				owner
					.import(coordinate(scenario.role(), 2), replacement, None)
					.await
					.unwrap();
				if matches!(scenario, Scenario::Publication) {
					replacement_intent.peering.try_push(scenario.publication(2)).unwrap();
				} else {
					let workspace::Conversation::Room(room) = &mut replacement_intent.conversations.as_mut_slice()[0]
					else {
						panic!("room");
					};
					room.seat = Some(custody::FieldKey::new(
						NonZeroU64::new(1).unwrap(),
						NonZeroU64::new(2).unwrap(),
					));
				}
				owner.replace_workspace(&replacement_intent).await.unwrap();
				let (base, _) = snapshot(&host, &source).await;
				assert!(
					mutate(
						&host,
						&source,
						"command",
						&command(scenario, "replacement-stale", base, 1)
					)
					.await
					.is_err()
				);
				assert!(
					mutate(&host, &other, "command", &args).await.is_err(),
					"equal policy cannot replay another source"
				);
				platform.tasks.borrow().last().unwrap().abort();
				for _ in 0..3 {
					environment::yield_turn().await;
				}
				assert_eq!(
					finished(&host, &other, "retired", &source).await.as_str(),
					Some("unknown")
				);
				if mode == "source-paused" {
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
				}
				if mode == "target-revoked" {
					host.send(
						&target_control,
						"revoke",
						&[Argument::Bytes(
							glowcap::loam::control_revision(&host, &target_control)
								.await
								.unwrap()
								.to_be_bytes()
								.to_vec(),
						)],
					)
					.await
					.unwrap();
				}
				if mode == "committed" {
					platform.observation_suspended.set(true);
				}
				platform.suspended.set(false);
				owner.resume_pending().unwrap();
				if mode == "committed" {
					while calls.get() == 0 {
						// Observation is suspended, so an ordinary status call
						// drives the Host while the exact execution stays held.
						host.send(&other, "effect-status", &["retired".into(), source.clone().into()])
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
						environment::yield_turn().await;
					}
					refuse_settlement.set(true);
					platform.observation_suspended.set(false);
					owner.resume_pending().unwrap();
					assert_eq!(
						finished(&host, &other, "retired", &source).await.as_str(),
						Some("unknown")
					);
					refuse_settlement.set(false);
					owner.resume_pending().unwrap();
				}
				let expected = match mode {
					"committed" => "committed",
					"target-revoked" | "malformed" => "unknown",
					"source-paused" => "unsent",
					_ => unreachable!("declared retirement case"),
				};
				assert_eq!(
					finished(&host, &other, "retired", &source).await.as_str(),
					Some(expected),
					"{mode}"
				);
				assert_eq!(calls.get(), usize::from(matches!(mode, "committed" | "malformed")));
				if matches!(mode, "committed" | "source-paused") {
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
				}
				assert_eq!(
					snapshot(&host, &source).await.1,
					replacement_intent,
					"settlement cannot clear replacement authority"
				);
				let canonical = serde_json::to_string(&(
					"retired",
					args[1].as_i64().unwrap(),
					scenario.name(),
					[scenario.id(), args[4].as_str().unwrap()],
				))
				.unwrap();
				let result = host
					.send(&source, "effect-result", &["retired".into(), canonical.clone().into()])
					.await
					.unwrap();
				if expected == "unknown" {
					unknown_reason(&result);
				} else if expected == "unsent" {
					let [status, reason] = result.as_list().expect("Host refusal preserves its diagnostic") else {
						panic!("known absence diagnostic");
					};
					assert_eq!(status.as_str(), Some("refused"));
					let reason = reason.as_str().expect("scalar refusal reason");
					assert!(
						!reason.is_empty() && reason.encode_utf16().count() <= custody::MAX_OBSERVATION_REASON_UNITS
					);
				} else {
					assert_eq!(
						result.as_str(),
						Some(if mode == "committed" { "null" } else { expected })
					);
				}
				assert_eq!(
					mutate(&host, &source, "command", &args).await.unwrap().as_str(),
					Some(expected)
				);
				owner.resume_pending().unwrap();
				assert_eq!(
					calls.get(),
					usize::from(matches!(mode, "committed" | "malformed")),
					"warm recovery never redispatches"
				);
				// Cold replay authenticates a durable source without restoring expired
				// target custody or requiring the current selected live target to work.
				owner.close().await.unwrap();
				attachment.close().await.unwrap();
				host.close(PendingWork::Cancel).await.unwrap();
				drop(owner);
				environment::close(&mut store).await;
				drop(store);
				let mut reopened = database.open(false, &schemas, limits).await;
				let host = Host::from_seed([123; 32]).unwrap();
				let cold_calls = Rc::new(Cell::new(0));
				let owner = managed::Session::new(
					host.clone(),
					Platform::default(),
					std::num::NonZeroUsize::new(8192).unwrap(),
				);
				let mut attachment = reopened
					.attach(
						&host,
						vec![
							owner.registration(),
							target_registration(cold_calls.clone(), malformed, &case),
						],
					)
					.unwrap();
				let (root, root_control) =
					environment::restore(&attachment, loam::Resource::decode(resource.encode())).await;
				owner.bind(root.clone(), root_control.clone()).unwrap();
				// Derivation receipts recover the exact source used by the original
				// command; a fresh same-policy derivation cannot authenticate replay.
				let value = host
					.send(
						&root,
						"derive-managed",
						&terms.managed_derive_arguments(sequence, Scope::Object, 1, powers),
					)
					.await
					.unwrap();
				let source = Ref::try_from(&value.as_list().unwrap()[0]).unwrap();
				assert_eq!(
					mutate(&host, &source, "command", &args).await.unwrap().as_str(),
					Some(expected)
				);
				assert_eq!(
					host.send(&source, "effect-result", &["retired".into(), canonical.into()])
						.await
						.unwrap(),
					result
				);
				assert_eq!(
					cold_calls.get(),
					0,
					"cold unresolved recovery cannot justify retirement"
				);
				owner.close().await.unwrap();
				attachment.close().await.unwrap();
				host.close(PendingWork::Cancel).await.unwrap();
				drop(owner);
				environment::close(&mut reopened).await;
				drop(reopened);
				database.remove();
			})
			.await
			.expect("retirement has bounded progress");
		})
		.await;
}
