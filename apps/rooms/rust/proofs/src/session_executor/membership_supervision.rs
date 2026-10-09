//! Automatic room setup retains its actual installed actor and optional facets.
use super::*;
use rooms_glowcap::client::workspace::Workspace;

struct HoldExecution {
	inner: Box<dyn Content>,
	platform: Platform,
	admitted: Rc<Cell<bool>>,
}
impl Content for HoldExecution {
	fn dependent_requirement(&self, input: Invocation<'_>) -> Result<Requirement> {
		self.inner.dependent_requirement(input)
	}
	fn requirement(&self, input: Invocation<'_>) -> Result<Requirement> {
		self.inner.requirement(input)
	}
	fn references(&self, input: Invocation<'_>) -> Result<Vec<loam::ReferenceRequest>> {
		self.inner.references(input)
	}
	fn invoke(&self, call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
		let reply = self.inner.invoke(call, input)?;
		if input.verb == "command" {
			self.platform.suspended.set(true);
			self.admitted.set(true);
		}
		Ok(reply)
	}
}

#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn supervised_room_keeps_actual_inbox_and_independent_lifetime() {
	run().await;
}
pub(super) async fn run() {
	for options in [0, 3, 4, 5, 6, 7] {
		tokio::task::LocalSet::new()
			.run_until(async {
				environment::within(10_000, async {
					let database = Database::new("membership-supervision");
					let mut schemas = managed::schemas();
					schemas.push(membership_results::MEMBER);
					let mut limits = crate::session_storage::limits_for(
						24,
						8,
						loam::ValueBounds {
							values: 48,
							capabilities: 12,
							bytes: 8192,
							..Default::default()
						},
					);
					limits.pending_bytes = limits.call_bytes * limits.max_operations;
					limits.ingress_bytes = limits.pending_bytes;
					// Workspace reception overlaps the initiating session window
					// and upstream subscription window. Each managed window owns
					// at most record_capacity rows plus descriptor/directory; the
					// enclosing endpoints and receipt/publication rows stay held too.
					limits.cache_slots = 3 * (limits.record_capacity + 2) + 5;
					limits.resident_bytes = limits.cache_slots * limits.record_bytes;
					limits.max_leases = limits.cache_slots * limits.max_operations;
					// Private/public endpoint pairs, four upstream pairs, shared
					// content/inventory observers, and retained callback/observation
					// pairs across the aggregate replacement journey.
					limits.max_references = 32;
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
					let foreign = if options == 4 {
						Some(
							environment::create(
								&store,
								&policy,
								schemas[0],
								&managed::initial_payload(
									rooms_application::content::session::workspace::Connection::Relay,
								)
								.unwrap(),
								3,
							)
							.await,
						)
					} else {
						None
					};
					let mut resources = Vec::new();
					for payload in [
						b"entrance".as_slice(),
						if options == 7 { b"name" } else { b"seat" },
						b"topic",
						b"files",
					] {
						resources
							.push(environment::create(&store, &policy, membership_results::MEMBER, payload, 2).await);
					}
					let host = Host::from_seed([117; 32]).unwrap();
					let platform = Platform::default();
					let owner = managed::Session::new(
						host.clone(),
						platform.clone(),
						std::num::NonZeroUsize::new(8192).unwrap(),
					);
					let joins = Rc::new(Cell::new(0));
					let failures = Rc::new(std::cell::RefCell::new(Vec::new()));
					owner
						.on_trouble({
							let failures = failures.clone();
							move |operation, error| {
								failures.borrow_mut().push(format!("{operation}: {error}"));
							}
						})
						.unwrap();
					let retirements = Rc::new(Cell::new(0));
					let admitted = Rc::new(Cell::new(false));
					let mut content = owner.registration();
					if options == 5 {
						content.content = Box::new(HoldExecution {
							inner: content.content,
							platform: platform.clone(),
							admitted: admitted.clone(),
						});
					}
					let mut attachment = store
						.attach(
							&host,
							vec![
								content,
								membership_results::registration_with_retirement(
									joins.clone(),
									Rc::new(Cell::new(0)),
									Rc::new(Cell::new(0)),
									options,
									retirements.clone(),
								),
							],
						)
						.unwrap();
					attachment.start_live(None, 64).unwrap();
					let (root, root_control) = environment::restore(&attachment, resource).await;
					owner.bind(root, root_control.clone()).unwrap();
					owner.initialize().await.unwrap();
					owner
						.activity()
						.bind_incarnation(attachment.live_incarnation().unwrap().unwrap())
						.unwrap();
					let mut held = Vec::new();
					for resource in resources {
						held.push(environment::restore(&attachment, resource).await.0);
					}
					host.send(
						&held[0],
						"configure",
						&held[1..].iter().cloned().map(Argument::Reference).collect::<Vec<_>>(),
					)
					.await
					.unwrap();
					let wide = policy
						.value_for_kind(
							session::KIND,
							&session::SUPPORTED
								.iter()
								.map(|permission| permission.key())
								.collect::<Vec<_>>(),
							&[],
						)
						.unwrap();
					let (source, control) = owner
						.derive(
							wide,
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
					for (role, slot, reference) in [
						(custody::Role::RoomAccess, 1, &held[0]),
						(custody::Role::DirectoryAccess, 1, &held[0]),
						(custody::Role::SessionAccess, 7, &source),
					] {
						owner
							.import(requests::coordinate(role, slot), reference.clone(), None)
							.await
							.unwrap();
					}
					let mut intent = Case::kick().workspace(1);
					intent.directories.as_mut_slice()[0].nick =
						rooms_application::fields::Text::new("member".into()).unwrap();
					if options == 7 {
						intent.directories.as_mut_slice()[0].source = Some(custody::FieldKey::new(
							NonZeroU64::new(7).unwrap(),
							NonZeroU64::new(1).unwrap(),
						));
					}
					let session::workspace::Conversation::Room(row) = &mut intent.conversations.as_mut_slice()[0]
					else {
						unreachable!()
					};
					row.access = Some(super::key());
					row.moderator = None;
					row.source = Some(custody::FieldKey::new(
						NonZeroU64::new(7).unwrap(),
						NonZeroU64::new(1).unwrap(),
					));
					owner.replace_workspace(&intent).await.unwrap();
					let session::workspace::Conversation::Room(row) = &intent.conversations.as_slice()[0] else {
						unreachable!()
					};
					if let Some(foreign) = foreign {
						let (foreign, _) = environment::restore(&attachment, foreign).await;
						let selected = requests::coordinate(custody::Role::SessionAccess, 8);
						owner.import(selected, foreign, None).await.unwrap();
						let mut mismatched = row.clone();
						mismatched.source =
							Some(custody::FieldKey::new(selected.key.slot(), selected.key.generation()));
						let error = match owner.room_source(&mismatched, &intent).await {
							Ok(_) => panic!("foreign session cannot realize a local worker"),
							Err(error) => error,
						};
						assert_eq!(error.message(), Some("worker source belongs to another session"));
					}
					let received = Rc::new(Cell::new(0));
					platform.suspended.set(true);
					let receive = {
						let mut project = owner.activity_receiver(&managed::MembershipTarget::Room(
							row.id.text().as_str().unwrap().into(),
						));
						let received = received.clone();
						move |args: &[Argument], origin: &managed::InboxOrigin| {
							if !args.is_empty() {
								project(managed::MembershipEvent::Notification {
									arguments: args,
									origin,
								})?;
								return Ok(());
							}
							received.set(received.get() + 1);
							Ok(())
						}
					};
					let mut live = if options == 7 {
						owner
							.supervise_directory(
								&intent.directories.as_slice()[0],
								"ocapn://member.id",
								&mut realization::Entropy::new(),
								receive,
							)
							.await
					} else {
						owner
							.supervise_room(row, &intent, &mut realization::Entropy::new(), receive)
							.await
					}
					.unwrap();
					if options == 0 {
						// Installation has retained its candidate while this worker
						// is suspended. An unrelated edit must survive re-preparation.
						let mut intervening = intent.clone();
						intervening.standing =
							rooms_application::fields::Text::new("intervening installation edit".into()).unwrap();
						owner.replace_workspace(&intervening).await.unwrap();
					}
					publication_results::lifecycle(&host, &control, "pause").await;
					if options == 4 {
						platform.refuse_observation.set(true);
					}
					platform.suspended.set(false);
					assert!(live.ready().await.is_err(), "startup preserves a refused stage");
					for _ in 0..8 {
						environment::yield_turn().await;
					}
					platform.refuse_observation.set(false);
					assert_eq!(joins.get(), 0, "paused startup cannot subscribe");
					publication_results::lifecycle(&host, &control, "resume").await;
					live.retry();
					if options == 5 {
						while !admitted.get() {
							environment::yield_turn().await;
						}
						platform.deadline_ms.set(Some(2));
						assert!(live.close().await.is_err(), "pending upstream result retains cleanup");
						assert!(live.is_active(), "the original worker slot stays owned");
						assert_eq!(joins.get(), 0);
						assert_eq!(retirements.get(), 0);
						platform.deadline_ms.set(None);
						platform.suspended.set(false);
						assert!(
							environment::within(2_000, async {
								while joins.get() == 0 {
									environment::yield_turn().await;
								}
							})
							.await
							.is_some(),
							"retained executor did not progress: {:?}",
							failures.borrow()
						);
						live.close().await.unwrap();
						live.close().await.unwrap();
						assert!(!live.is_active());
						assert_eq!(joins.get(), 1);
						assert_eq!(retirements.get(), 1, "late actual result receives exact leave once");
						owner.close().await.unwrap();
						attachment.close().await.unwrap();
						host.close(PendingWork::Cancel).await.unwrap();
						environment::close(&mut store).await;
						database.remove();
						return;
					}
					if options == 6 {
						assert!(live.ready().await.is_err());
						for _ in 0..2 {
							assert!(live.close().await.is_err());
							assert!(live.is_active(), "uncertainty retains actual worker custody");
							owner.resume_pending().unwrap();
						}
						assert_eq!(joins.get(), 1, "unknown receipt cannot redispatch");
						assert_eq!(retirements.get(), 0, "unknown result cannot invent a target");
						assert!(owner.close().await.is_err());
						// Test teardown abandons the whole host incarnation. Production
						// must retain it and report refusal, as the assertions above pin.
						drop(live);
						drop(owner);
						for _ in 0..8 {
							environment::yield_turn().await;
						}
						attachment.close().await.unwrap();
						host.close(PendingWork::Cancel).await.unwrap();
						environment::close(&mut store).await;
						database.remove();
						return;
					}
					if options == 7 {
						live.ready().await.unwrap();
						assert_eq!(joins.get(), 1);
						live.close().await.unwrap();
						live.close().await.unwrap();
						assert_eq!(retirements.get(), 1, "directory cleanup selects its returned name");
						owner.close().await.unwrap();
						attachment.close().await.unwrap();
						host.close(PendingWork::Cancel).await.unwrap();
						environment::close(&mut store).await;
						database.remove();
						return;
					}
					live.ready().await.unwrap();
					live.ready().await.unwrap();
					assert_eq!(joins.get(), 1, "readiness observes one exact subscription");
					let workspace = Workspace::local(host.clone(), platform.clone(), source.clone());
					let installed = workspace.snapshot().await.unwrap();
					if options == 0 {
						assert_eq!(
							installed.intent.standing.text().as_str(),
							Some("intervening installation edit")
						);
					}
					let session::workspace::Conversation::Room(row) = &installed.intent.conversations.as_slice()[0]
					else {
						unreachable!()
					};
					assert!(row.seat.is_some());
					assert_eq!(row.topic.is_some(), options & 1 != 0);
					assert_eq!(row.files.is_some(), options & 2 != 0);
					let callback = owner
						.restore_custody(&[session::workspace::InboxSelection::room(row, &installed.intent)
							.unwrap()
							.coordinate()])
						.await
						.unwrap()
						.remove(0);
					if options == 0 {
						super::membership_standing::run(&host, &owner, &workspace, &held[1], &control).await;
						super::activity::run(&host, &owner, &platform, &source, &control, &callback).await;
					}
					host.send(&callback, "notify", &[]).await.unwrap();
					assert_eq!(received.get(), 1);
					publication_results::lifecycle(&host, &control, "pause").await;
					assert!(host.send(&callback, "notify", &[]).await.is_err());
					publication_results::lifecycle(&host, &control, "resume").await;
					host.send(&callback, "notify", &[]).await.unwrap();
					assert_eq!(received.get(), 2);
					if options == 4 {
						publication_results::lifecycle(&host, &control, "revoke").await;
						assert!(
							environment::within(2_000, async {
								while live.is_active() {
									environment::yield_turn().await;
								}
							})
							.await
							.is_some(),
							"child grant revocation retires membership without a workspace edit"
						);
						live.close().await.unwrap();
						assert_eq!(retirements.get(), 1, "revocation retires the upstream seat");
						assert!(host.send(&callback, "notify", &[]).await.is_err());
					} else if options == 0 {
						platform.refuse_observation.set(true);
						assert!(
							live.close().await.is_err(),
							"failed cancellation retains cleanup custody"
						);
						drop(live);
						for _ in 0..8 {
							environment::yield_turn().await;
						}
						let attempts = platform.refused_observations.get();
						for _ in 0..8 {
							environment::yield_turn().await;
						}
						assert_eq!(
							platform.refused_observations.get(),
							attempts,
							"abandoned failed cleanup waits without spinning"
						);
						assert!(
							owner.close().await.is_err(),
							"failed cancellation keeps the session barrier"
						);
						platform.refuse_observation.set(false);
						// Session close has begun. Retry its retained cleanup instead
						// of creating another member or substituting root authority.
						while owner.close().await.is_err() {
							environment::yield_turn().await;
						}
					} else {
						live.close().await.unwrap();
						live.close().await.unwrap();
						assert_eq!(retirements.get(), 1, "repeated close retires one exact seat");
						super::membership_coordination::run(&host, &owner, &source, &platform, &joins).await;
						super::workspace_supervision::run(&host, &owner, &source, &platform, &joins).await;
						let latest = workspace.snapshot().await.unwrap();
						let session::workspace::Conversation::Room(row) = &latest.intent.conversations.as_slice()[1]
						else {
							unreachable!()
						};
						platform.suspended.set(true);
						let abandoned_observer = owner
							.supervise_workspace(
								&source,
								"ocapn://member.id",
								realization::Entropy::seeded(500),
								managed::MembershipKinds::ALL,
								|_| Box::new(|_| Ok(Argument::Void)),
								|_| {},
							)
							.unwrap();
						drop(abandoned_observer);
						let abandoned = owner
							.supervise_room(row, &latest.intent, &mut realization::Entropy::new(), |_, _| Ok(()))
							.await
							.unwrap();
						drop(abandoned);
						assert!(
							owner.close().await.is_err(),
							"session waits for actual callback retirement"
						);
						platform.suspended.set(false);
						while owner.close().await.is_err() {
							environment::yield_turn().await;
						}
					}
					assert!(host.send(&callback, "notify", &[]).await.is_err());
					assert_eq!(joins.get(), if options == 3 { 9 } else { 1 });
					owner.close().await.unwrap();
					attachment.close().await.unwrap();
					host.close(PendingWork::Cancel).await.unwrap();
					environment::close(&mut store).await;
					database.remove();
				})
				.await
				.expect("membership supervision has bounded progress");
			})
			.await;
	}
}
