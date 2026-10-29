//! A gesture pays once. Its private forwarding still checks live authority.
use super::*;

#[tokio::test]
async fn admitted_command_forwards_once_and_next_gesture_is_refused() {
	run(Scenario::SingleAllowance).await;
}

#[tokio::test]
#[ignore = "same-host shared-session cost sample; run alone with an idle host"]
async fn ordinary_shared_session_cost_sample() {
	run(Scenario::OrdinaryCost).await;
}

enum Scenario {
	SingleAllowance,
	OrdinaryCost,
}
async fn run(scenario: Scenario) {
	tokio::task::LocalSet::new()
		.run_until(async {
			environment::within(10_000, async {
				let database = Database::new("admission-forward");
				let mut schemas = managed::schemas();
				schemas.push(TARGET);
				let mut limits = crate::session_storage::limits_for(
					16,
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
					&managed::initial_payload(session::workspace::Connection::Relay).unwrap(),
					3,
				)
				.await;
				let upstream = environment::create(&store, &policy, TARGET, b"original", 1).await;
				let host = Host::from_seed([185; 32]).unwrap();
				host.set_advertised_locator(&glowcap::Locator::bare("tcp", "127.0.0.1:9012"))
					.unwrap();
				let owner = managed::Session::new(
					host.clone(),
					Platform::default(),
					std::num::NonZeroUsize::new(8192).unwrap(),
				);
				if matches!(scenario, Scenario::SingleAllowance) {
					owner
						.configure_admission(
							rooms_application::admission::Settings::parse(
								|key| match key {
									"admission-rates" => Some("message=1/1".into()),
									"admission-aggregate-scale" => Some("1".into()),
									_ => None,
								},
								4096,
								8,
							)
							.unwrap(),
						)
						.unwrap();
				}
				let case = Case::subject();
				let calls = Rc::new(Cell::new(0));
				let mut attachment = store
					.attach(
						&host,
						vec![
							owner.registration(),
							target_registration(calls.clone(), Rc::new(Cell::new(false)), &case),
						],
					)
					.unwrap();
				environment::start_live(&attachment, None, 32).await;
				let (root, control) = environment::restore(&attachment, resource).await;
				owner.bind(root.clone(), control).unwrap();
				owner.initialize().await.unwrap();
				let (target, _) = environment::restore(&attachment, upstream).await;
				owner.import(case.coordinate(1), target.clone(), None).await.unwrap();
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
				owner.replace_workspace(&case.workspace(1)).await.unwrap();
				match scenario {
					Scenario::SingleAllowance => {
						let (args, _) = requests::command(&host, &root, "first", case.name, &case.args).await;
						assert_eq!(
							mutate(&host, &root, "command", &args).await.unwrap().as_str(),
							Some("pending")
						);
						assert_eq!(finished(&host, &root, "first", &root).await.as_str(), Some("committed"));
						assert_eq!(
							calls.get(),
							1,
							"private continuation must not charge the first gesture again"
						);
						let (args, _) = requests::command(&host, &root, "second", case.name, &case.args).await;
						let error = mutate(&host, &root, "command", &args).await.unwrap_err();
						assert!(error.to_string().contains("rate-limited"), "{error}");
						assert_eq!(calls.get(), 1, "refused gesture must not dispatch");
					}
					Scenario::OrdinaryCost => {
						let permissions: Vec<_> = session::SUPPORTED.iter().map(|p| p.key()).collect();
						let terms = policy.value_for_kind(session::KIND, &permissions, &[]).unwrap();
						let mut sources = Vec::new();
						for _ in 0..4 {
							sources.push(owner.derive(terms, 1, ControlPowers::default()).await.unwrap().0);
						}
						for (index, source) in sources.iter().enumerate() {
							post(&host, source, &format!("warm-{index}"), &case).await;
						}
						let started = std::time::Instant::now();
						for (index, source) in sources.iter().enumerate() {
							for message in 0..8 {
								post(&host, source, &format!("sample-{index}-{message}"), &case).await;
							}
						}
						println!(
							"shared cost: 4 collaborators, 32 commands, average completion us={}",
							started.elapsed().as_micros() / 32
						);
						assert_eq!(
							calls.get(),
							36,
							"every warm and sampled command reaches its exact target once"
						);
					}
				}
				owner.close().await.unwrap();
				attachment.close().await.unwrap();
				host.close(PendingWork::Cancel).await.unwrap();
				drop(owner);
				environment::close(&mut store).await;
				drop(store);
				database.remove();
			})
			.await
			.expect("admission settles within its deadline");
		})
		.await;
}

async fn post(host: &Host, source: &Ref, id: &str, case: &Case) {
	let (args, _) = requests::command(host, source, id, case.name, &case.args).await;
	assert_eq!(
		mutate(host, source, "command", &args).await.unwrap().as_str(),
		Some("pending")
	);
	assert_eq!(finished(host, source, id, source).await.as_str(), Some("committed"));
}
