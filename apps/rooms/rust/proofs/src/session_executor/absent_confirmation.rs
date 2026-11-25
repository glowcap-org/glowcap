//! A job that paused while its commit was still unconfirmed, and whose commit
//! is then confirmed absent, holds a seat and no receipt. The next admission
//! and a release of its operation retire it. A job whose commit installs
//! instead keeps its seat and resumes.
use super::*;

const REFUSED: &str = "receipt callback refused after worker installation";

struct Rig {
	host: Host,
	root: Ref,
	owner: managed::Session<Platform>,
	platform: Platform,
	refuse: Rc<Cell<bool>>,
	case: Case,
}
impl Rig {
	/// Send `id` so its callback refuses after the worker installed, and
	/// interrupt that worker before its first poll: the job pauses on the
	/// commit it was installed to confirm, and the commit confirms absent.
	/// Returns the exact intent.
	async fn stall_absent(&self, id: &str) -> String {
		let (args, canonical) = requests::command(&self.host, &self.root, id, self.case.name, &self.case.args).await;
		self.refuse.set(true);
		self.platform.suspended.set(true);
		let error = mutate(&self.host, &self.root, "command", &args).await.unwrap_err();
		self.refuse.set(false);
		assert!(error.to_string().contains(REFUSED), "{id}: {error}");
		self.platform.tasks.borrow().last().unwrap().abort();
		self.platform.suspended.set(false);
		for _ in 0..3 {
			environment::yield_turn().await;
		}
		assert!(self.owner.holds_request(id), "{id}: the paused job holds its seat");
		canonical
	}
	async fn command(&self, id: &str) -> glowcap::Result<Argument> {
		let (args, _) = requests::command(&self.host, &self.root, id, self.case.name, &self.case.args).await;
		mutate(&self.host, &self.root, "command", &args).await
	}
}

#[tokio::test]
async fn confirmed_absent_commits_free_their_seats_and_an_installed_one_keeps_its_own() {
	rooms_testing::local_set::run(async {
		environment::within(20_000, async {
			let database = Database::new("absent-confirmation");
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
			let host = Host::from_seed([186; 32]).unwrap();
			host.set_advertised_locator(&glowcap::Locator::bare("tcp", "127.0.0.1:9012"))
				.unwrap();
			let platform = Platform::default();
			let owner = managed::Session::new(
				host.clone(),
				platform.clone(),
				std::num::NonZeroUsize::new(8192).unwrap(),
			);
			let refuse = Rc::new(Cell::new(false));
			let mut registration = owner.registration();
			registration.content = Box::new(AbortAfterAdmission {
				inner: registration.content,
				refuse: refuse.clone(),
				refuse_settlement: Rc::new(Cell::new(false)),
			});
			let case = Case::subject();
			let calls = Rc::new(Cell::new(0));
			let mut attachment = store
				.attach(
					&host,
					vec![
						registration,
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
			let rig = Rig {
				host: host.clone(),
				root: root.clone(),
				owner,
				platform,
				refuse,
				case,
			};

			// More absent jobs than the table holds never block an admission:
			// each admission retires the one before it.
			for index in 0..custody::MAX_EFFECTS + 1 {
				rig.stall_absent(&format!("absent-{index}")).await;
			}
			assert_eq!(
				rig.command("after-absent").await.unwrap().as_str(),
				Some("pending"),
				"an admission after the stalled commits is not refused for places"
			);
			assert_eq!(
				finished(&host, &root, "after-absent", &root).await.as_str(),
				Some("committed")
			);
			for index in 0..custody::MAX_EFFECTS + 1 {
				assert!(!rig.owner.holds_request(&format!("absent-{index}")));
			}
			assert_eq!(calls.get(), 1);

			// A release of the operation retires its job with no admission.
			let intent = rig.stall_absent("absent-released").await;
			assert_eq!(
				host.send(
					&root,
					"release-effect",
					&["absent-released".into(), intent.as_str().into()]
				)
				.await
				.unwrap(),
				Argument::String("released".into())
			);
			assert!(
				!rig.owner.holds_request("absent-released"),
				"the release retired the job whose commit never landed"
			);
			// A release for an operation of another source never reaches the job.
			let intent = rig.stall_absent("absent-foreign").await;
			let permissions: Vec<_> = session::SUPPORTED.iter().map(|p| p.key()).collect();
			let terms = policy.value_for_kind(session::KIND, &permissions, &[]).unwrap();
			let (foreign, _) = rig.owner.derive(terms, 1, full_control(terms)).await.unwrap();
			assert_eq!(
				host.send(
					&foreign,
					"release-effect",
					&["absent-foreign".into(), intent.as_str().into()]
				)
				.await
				.unwrap(),
				Argument::String("released".into())
			);
			assert!(
				rig.owner.holds_request("absent-foreign"),
				"another source retires nothing"
			);

			// A commit that installs after the deadline is not retired. Only the
			// wait on the commit's confirmation expires, so the job pauses
			// confirming it.
			let refused = rig.platform.refused_observations.get();
			rig.platform.only.set(Some("Continuation"));
			rig.platform.refuse_observation.set(true);
			let (args, canonical) = requests::command(&host, &root, "late", rig.case.name, &rig.case.args).await;
			assert_eq!(
				mutate(&host, &root, "command", &args).await.unwrap().as_str(),
				Some("pending")
			);
			assert_eq!(finished(&host, &root, "late", &root).await.as_str(), Some("unknown"));
			rig.platform.refuse_observation.set(false);
			rig.platform.only.set(None);
			assert_eq!(
				rig.platform.refused_observations.get(),
				refused + 1,
				"exactly the confirmation wait expired"
			);
			assert_eq!(
				rig.command("after-late").await.unwrap().as_str(),
				Some("pending"),
				"an admission sweeps the table"
			);
			assert!(rig.owner.holds_request("late"), "a pending commit's job keeps its seat");
			assert!(
				!rig.owner.holds_request("absent-foreign"),
				"the sweep retired the absent one"
			);
			assert_eq!(
				host.send(&root, "resume-effect", &["late".into(), canonical.as_str().into()])
					.await
					.unwrap()
					.as_str(),
				Some("pending")
			);
			assert_eq!(finished(&host, &root, "late", &root).await.as_str(), Some("committed"));

			rig.owner.close().await.unwrap();
			attachment.close().await.unwrap();
			host.close(PendingWork::Cancel).await.unwrap();
			drop(rig);
			environment::close(&mut store).await;
			drop(store);
			database.remove();
		})
		.await
		.expect("absent confirmations settle within the deadline");
	})
	.await;
}
