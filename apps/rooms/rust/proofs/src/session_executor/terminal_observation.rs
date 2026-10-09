//! Failed terminal observations wake durable readers and survive cold recovery.
use super::*;
use rooms_glowcap::client::{access::ObservationRequest, workspace::Workspace};

struct FailingTarget(Rc<Cell<usize>>, bool);
impl Content for FailingTarget {
	fn requirement(&self, _: Invocation<'_>) -> Result<Requirement> {
		Requirement::new(&[], &[])
	}
	fn invoke(&self, _: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
		assert_eq!(input.verb, "down");
		self.0.set(self.0.get() + 1);
		if self.1 {
			Ok(true.into())
		} else {
			Err(loam::refusal("relay registration refused"))
		}
	}
}
fn registration(calls: Rc<Cell<usize>>, malformed: bool) -> Registration {
	Registration {
		schema: TARGET.id,
		version: 1,
		graph: None,
		methods: vec![Method {
			verb: "down".into(),
			retry: Retry::ReadOnly,
		}],
		content: Box::new(FailingTarget(calls, malformed)),
	}
}
async fn reason(host: &Host, source: &Ref, canonical: &str) -> String {
	let value = host
		.send(source, "effect-result", &["failed".into(), canonical.into()])
		.await
		.unwrap();
	unknown_reason(&value).into()
}

#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn terminal_observation_wakes_original_source_and_preserves_reason_without_redispatch() {
	run().await;
}
pub(super) async fn run() {
	for (malformed, interrupted_settlement) in [(false, false), (true, false), (true, true)] {
		tokio::task::LocalSet::new()
			.run_until(async {
				environment::within(10_000, async {
					let database = Database::new("terminal-observation");
					let mut schemas = managed::schemas();
					schemas.push(TARGET);
					let mut limits = crate::session_storage::limits_for(
						16,
						8,
						loam::ValueBounds {
							values: 64,
							capabilities: 8,
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
					let target = environment::create(&store, &policy, TARGET, b"original", 1).await;
					let calls = Rc::new(Cell::new(0));
					let platform = Platform::default();
					let host = Host::from_seed([171; 32]).unwrap();
					host.set_advertised_locator(&glowcap::Locator::bare("tcp", "127.0.0.1:9012"))
						.unwrap();
					let owner = managed::Session::new(
						host.clone(),
						platform.clone(),
						std::num::NonZeroUsize::new(8192).unwrap(),
					);
					let refuse_settlement = Rc::new(Cell::new(interrupted_settlement));
					let mut registration_owner = owner.registration();
					registration_owner.content = Box::new(AbortAfterAdmission {
						inner: registration_owner.content,
						refuse: Rc::new(Cell::new(false)),
						refuse_settlement: refuse_settlement.clone(),
					});
					let mut attachment = store
						.attach(&host, vec![registration_owner, registration(calls.clone(), malformed)])
						.unwrap();
					attachment.start_live(None, 32).unwrap();
					let (root, control) = environment::restore(&attachment, resource).await;
					owner.bind(root.clone(), control.clone()).unwrap();
					owner.initialize().await.unwrap();
					let (target, _) = environment::restore(&attachment, target).await;
					owner
						.import(requests::coordinate(custody::Role::Operations, 1), target, None)
						.await
						.unwrap();
					let case = Case::operations();
					owner.replace_workspace(&case.workspace(1)).await.unwrap();
					let workspace = Workspace::local(host.clone(), platform.clone(), root.clone());
					let request =
						ObservationRequest::new_live(workspace.mutation_sequence().await.unwrap(), [1; 16]).unwrap();
					let observation = workspace.observe(&request).await.unwrap();
					let (args, canonical) = requests::command(&host, &root, "failed", case.name, &case.args).await;
					platform.suspended.set(true);
					assert_eq!(
						mutate(&host, &root, "command", &args).await.unwrap().as_str(),
						Some("pending")
					);
					let cursor = *observation.poll(None).await.unwrap().view().cursor;
					let reader = host
						.send(&root, "effect-reader", &["failed".into(), canonical.clone().into()])
						.await
						.unwrap();
					let reader = Ref::try_from(&reader).unwrap();
					let waiting = host.send(&reader, "read", &["failed".into(), root.clone().into()]);
					platform.suspended.set(false);
					assert_eq!(waiting.await.unwrap().as_str(), Some("unknown"));
					if interrupted_settlement {
						assert_eq!(
							host.send(&root, "effect-result", &["failed".into(), canonical.clone().into()])
								.await
								.unwrap()
								.as_str(),
							Some("unknown")
						);
						refuse_settlement.set(false);
						owner.resume_pending().unwrap();
					}
					observation.receive(&cursor).await.unwrap();
					assert_eq!(finished(&host, &root, "failed", &root).await.as_str(), Some("unknown"));
					let original_reason = reason(&host, &root, &canonical).await;
					assert!(
						original_reason.contains(if malformed {
							"invalid effect result"
						} else {
							"ApplicationRefused"
						}),
						"{original_reason}"
					);
					let permissions: Vec<_> = session::SUPPORTED.iter().map(|permission| permission.key()).collect();
					let terms = policy.value_for_kind(session::KIND, &permissions, &[]).unwrap();
					let (sibling, _) = owner.derive(terms, 1, ControlPowers::default()).await.unwrap();
					assert!(
						host.send(&sibling, "effect-reader", &["failed".into(), canonical.clone().into()])
							.await
							.is_err()
					);
					assert!(
						host.send(&sibling, "effect-result", &["failed".into(), canonical.clone().into()])
							.await
							.is_err()
					);
					assert_eq!(
						mutate(&host, &root, "command", &args).await.unwrap().as_str(),
						Some("unknown")
					);
					assert!(
						host.send(&root, "resume-effect", &["failed".into(), canonical.clone().into()])
							.await
							.is_err()
					);
					assert_eq!(calls.get(), 1, "failure never authorizes redispatch");
					observation.cancel().await.unwrap();
					drop(observation);
					owner.close().await.unwrap();
					attachment.close().await.unwrap();
					host.close(PendingWork::Cancel).await.unwrap();
					drop(owner);
					environment::close(&mut store).await;
					drop(store);
					let mut store = database.open(false, &schemas, limits).await;
					let host = Host::from_seed([171; 32]).unwrap();
					let owner = managed::Session::new(
						host.clone(),
						Platform::default(),
						std::num::NonZeroUsize::new(8192).unwrap(),
					);
					let mut attachment = store
						.attach(
							&host,
							vec![owner.registration(), registration(calls.clone(), malformed)],
						)
						.unwrap();
					let (root, control) = environment::restore(&attachment, resource).await;
					owner.bind(root.clone(), control).unwrap();
					assert_eq!(reason(&host, &root, &canonical).await, original_reason);
					assert!(
						host.send(&root, "resume-effect", &["failed".into(), canonical.into()])
							.await
							.is_err()
					);
					assert_eq!(calls.get(), 1, "cold recovery never reconstructs dispatch");
					owner.close().await.unwrap();
					attachment.close().await.unwrap();
					host.close(PendingWork::Cancel).await.unwrap();
					drop(owner);
					environment::close(&mut store).await;
					drop(store);
					database.remove();
				})
				.await
				.expect("terminal observation has bounded progress");
			})
			.await;
	}
}
