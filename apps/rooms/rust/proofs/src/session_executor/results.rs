//! Real foreign result custody survives settlement refusal and source restart.
use super::*;
use glowcap::{CaptpVersion, Locator, Session};

#[derive(Clone, Copy)]
enum ResultCase {
	Stewardship,
	RoomLink,
	RoomModerator,
}
impl ResultCase {
	fn name(self) -> &'static str {
		match self {
			Self::Stewardship => "operator",
			Self::RoomLink => "ensureRoomLink",
			Self::RoomModerator => "issueRoomModerator",
		}
	}
	fn role(self) -> custody::Role {
		match self {
			Self::Stewardship => custody::Role::Operator,
			Self::RoomLink | Self::RoomModerator => custody::Role::RoomControl,
		}
	}
	fn args(self) -> Vec<String> {
		match self {
			Self::Stewardship => vec![
				serde_json::to_string(&key::<custody::Operator>()).unwrap(),
				"giveModerator".into(),
				"room".into(),
			],
			Self::RoomLink | Self::RoomModerator => vec!["conversation".into()],
		}
	}
	fn workspace(self) -> Intent {
		match self {
			Self::Stewardship => {
				let mut workspace = Intent::empty();
				workspace.operators = List::new(vec![key()]).unwrap();
				workspace
			}
			Self::RoomLink | Self::RoomModerator => Case::policy(false).workspace(1),
		}
	}
}
struct Operator {
	uri: String,
	calls: Rc<Cell<usize>>,
	case: ResultCase,
}
impl Content for Operator {
	fn requirement(&self, _: Invocation<'_>) -> Result<Requirement> {
		Requirement::new(&[], &[])
	}
	fn invoke(&self, _: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
		if input.verb == "link" {
			assert!(input.args.is_empty());
			self.calls.set(self.calls.get() + 1);
			return Ok(self.uri.clone().into());
		}
		assert!(matches!(input.verb, "giveSteward" | "revokeSteward"));
		let issued = input.verb == "giveSteward";
		self.calls.set(self.calls.get() + 1);
		if matches!(self.case, ResultCase::RoomModerator) {
			assert!(issued && input.args.is_empty());
			let parsed = glowcap::parse_sturdyref(&self.uri, CaptpVersion::V1_0)?;
			let token = std::str::from_utf8(&parsed.swissnum).unwrap();
			return Ok(Argument::List(vec![
				self.uri.clone().into(),
				rooms_application::room::authority::room_identity(token).unwrap().into(),
				self.uri.clone().into(),
			]));
		}
		Ok(Argument::List(vec![
			"room".into(),
			"Room".into(),
			"listed".into(),
			1.into(),
			issued.into(),
			if issued {
				self.uri.clone().into()
			} else {
				Argument::Void
			},
		]))
	}
}
fn registration(uri: &str, calls: &Rc<Cell<usize>>, case: ResultCase) -> Registration {
	Registration {
		schema: TARGET.id,
		version: 1,
		graph: None,
		methods: ["giveSteward", "revokeSteward", "link"]
			.into_iter()
			.map(|verb| Method {
				verb: verb.into(),
				retry: Retry::ReadOnly,
			})
			.collect(),
		content: Box::new(Operator {
			uri: uri.into(),
			calls: calls.clone(),
			case,
		}),
	}
}
pub(super) async fn connect(source: &Host, exporter: &Host, locator: &Locator, gate: gate::Gate) -> (Session, Session) {
	let (left, right) = tokio::io::duplex(4096);
	let budget = Some(std::time::Duration::from_secs(2));
	let (dialed, accepted) = tokio::join!(
		Session::dial_over(source, locator, gate::Stream { inner: left, gate }, budget),
		Session::accept_over(exporter, "tcp", "127.0.0.1:9011", "127.0.0.1:9011", right, budget)
	);
	(dialed.unwrap(), accepted.unwrap())
}
async fn disclosed(host: &Host, root: &Ref, intent: &str, case: ResultCase) -> (String, Ref) {
	let answer = host
		.send(root, "effect-result", &["issued".into(), intent.into()])
		.await
		.unwrap();
	let [data, fields] = answer.as_list().unwrap() else {
		panic!("typed capability result")
	};
	let data = data.as_str().unwrap();
	assert!(
		!data.contains("ocapn:"),
		"bearer text never enters persisted result data"
	);
	let key = match case {
		ResultCase::Stewardship => {
			let row: session::results::Stewardship = serde_json::from_str(data).unwrap();
			row.steward.expect("issued moderator")
		}
		ResultCase::RoomLink => {
			let row: session::results::RoomLink = serde_json::from_str(data).unwrap();
			row.room
		}
		ResultCase::RoomModerator => {
			let row: session::results::RoomModerator = serde_json::from_str(data).unwrap();
			row.moderator
		}
	};
	let [field] = fields.as_list().unwrap() else {
		panic!("one exact returned field")
	};
	let [coordinate, reference] = field.as_list().unwrap() else {
		panic!("coordinate and held capability")
	};
	let coordinate: custody::Coordinate = serde_json::from_str(coordinate.as_str().unwrap()).unwrap();
	assert_eq!(coordinate.role, custody::Role::RoomAccess);
	assert_eq!(coordinate.key.slot(), key.slot());
	assert_eq!(coordinate.key.generation(), key.generation());
	let reference = Ref::try_from(reference).unwrap();
	assert_eq!(
		host.send(&reference, "identity", &[]).await.unwrap().as_str(),
		Some("moderator")
	);
	(data.into(), reference)
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn typed_result_saves_exact_foreign_authority_and_replays_after_cold_restart() {
	run_case(ResultCase::Stewardship).await;
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn room_link_saves_exact_foreign_authority_and_replays_after_cold_restart() {
	run_case(ResultCase::RoomLink).await;
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn moderator_issuance_saves_exact_foreign_authority_and_replays_after_cold_restart() {
	run_case(ResultCase::RoomModerator).await;
}
#[cfg(target_arch = "wasm32")]
pub(super) async fn run() {
	for case in [ResultCase::Stewardship, ResultCase::RoomLink, ResultCase::RoomModerator] {
		run_case(case).await;
	}
}
async fn run_case(case: ResultCase) {
	tokio::task::LocalSet::new()
		.run_until(async {
			environment::within(10_000, async {
				let database = Database::new(&format!("foreign-result-{}", case.name()));
				let exporter = Host::from_seed([114; 32]).unwrap();
				let locator = Locator::bare("tcp", "127.0.0.1:9011");
				exporter.set_advertised_locator(&locator).unwrap();
				let swiss = exporter
					.publish_durable(|| {
						Box::new(|verb, _| {
							assert_eq!(verb, "identity");
							Ok("moderator".into())
						})
					})
					.unwrap();
				let uri = glowcap::format_sturdyref(&locator, swiss.as_bytes(), CaptpVersion::V1_0).unwrap();
				let other = exporter
					.publish_durable(|| Box::new(|_, _| Ok("other".into())))
					.unwrap();
				let other_uri = glowcap::format_sturdyref(&locator, other.as_bytes(), CaptpVersion::V1_0).unwrap();
				let mut schemas = managed::schemas();
				schemas.push(TARGET);
				// This trace uses a storage fixture allowance, not the production
				// executor invocation profile; production sizing lands with startup.
				let mut limits = crate::session_storage::limits_for(
					16,
					8,
					loam::ValueBounds {
						values: 32,
						capabilities: 8,
						bytes: 4096,
						..Default::default()
					},
				);
				limits.pending_bytes = limits.call_bytes.checked_mul(limits.max_operations).unwrap();
				limits.ingress_bytes = limits.pending_bytes;
				limits.max_leases = limits.max_leases.checked_mul(limits.max_operations).unwrap();
				let mut store = database.open(true, &schemas, limits).await;
				let policy = rooms_glowcap::policy::descriptor().unwrap();
				let resource = environment::create(
					&store,
					&policy,
					schemas[0],
					&managed::initial_payload(rooms_application::content::session::workspace::Connection::Relay)
						.unwrap(),
					2,
				)
				.await;
				let operator = environment::create(&store, &policy, TARGET, b"operator", 1).await;
				let calls = Rc::new(Cell::new(0));
				let host = Host::from_seed([116; 32]).unwrap();
				let gate = gate::Gate::default();
				let (dialed, accepted) = connect(&host, &exporter, &locator, gate.clone()).await;
				let platform = Platform::default();
				let owner = managed::Session::new(
					host.clone(),
					platform.clone(),
					std::num::NonZeroUsize::new(4096).unwrap(),
				);
				let refuse_settlement = Rc::new(Cell::new(true));
				let mut content = owner.registration();
				content.content = Box::new(AbortAfterAdmission {
					inner: content.content,
					refuse: Rc::new(Cell::new(false)),
					refuse_settlement: refuse_settlement.clone(),
				});
				let mut attachment = store
					.attach(&host, vec![content, registration(&uri, &calls, case)])
					.unwrap();
				let (root, root_control) = environment::restore(&attachment, resource).await;
				owner.bind(root.clone(), root_control.clone()).unwrap();
				owner.initialize().await.unwrap();
				let (target, _) = environment::restore(&attachment, operator).await;
				if matches!(case, ResultCase::RoomLink | ResultCase::RoomModerator) {
					owner
						.import(
							custody::Coordinate {
								role: custody::Role::DirectoryAccess,
								key: key(),
							},
							target.clone(),
							None,
						)
						.await
						.unwrap();
				}
				owner
					.import(
						custody::Coordinate {
							role: case.role(),
							key: key(),
						},
						target,
						None,
					)
					.await
					.unwrap();
				let workspace = case.workspace();
				owner.replace_workspace(&workspace).await.unwrap();
				let snapshot = host.send(&root, "snapshot", &[]).await.unwrap();
				let base = snapshot.as_list().unwrap()[0].as_i64().unwrap();
				let command_args = case.args();
				let mut args = vec!["issued".into(), base.into(), case.name().into()];
				args.extend(command_args.iter().cloned().map(Argument::String));
				let intent = serde_json::to_string(&("issued", base, case.name(), &command_args)).unwrap();
				let imported = custody::Coordinate {
					role: custody::Role::RoomAccess,
					key: key(),
				};
				gate.block();
				platform.deadline_ms.set(Some(100));
				platform.deadline_after_parking.replace(Some(gate.clone()));
				mutate(&host, &root, "command", &args).await.unwrap();
				assert_eq!(finished(&host, &root, "issued", &root).await.as_str(), Some("unknown"));
				assert!(gate.observed(), "actual lookup bytes reached the parked transport");
				assert!(
					owner
						.import_result(&root, "issued", &intent, imported, imported)
						.await
						.is_err(),
					"an unresolved receipt supplies no result custody"
				);
				platform.deadline_ms.set(None);
				platform.deadline_after_parking.replace(None);
				gate.open();
				owner.resume_pending().unwrap();
				assert_eq!(finished(&host, &root, "issued", &root).await.as_str(), Some("unknown"));
				assert_eq!(calls.get(), 1);
				refuse_settlement.set(false);
				owner.resume_pending().unwrap();
				let observed = finished(&host, &root, "issued", &root).await;
				if observed.as_str() != Some("committed") {
					panic!("typed receipt {observed:?}; retained failure {:?}", owner.close().await);
				}
				let (data, actual) = disclosed(&host, &root, &intent, case).await;
				assert_eq!(actual, host.enliven(&uri).await.unwrap());
				let result_coordinate = serde_json::to_string(&custody::Coordinate {
					role: custody::Role::RoomAccess,
					key: key(),
				})
				.unwrap();
				let outcome = |reference: Ref, uri: &str| {
					Argument::List(vec![
						data.clone().into(),
						Argument::List(vec![Argument::List(vec![
							result_coordinate.clone().into(),
							Argument::Reference(reference),
							uri.into(),
						])]),
					])
				};
				let settle = |result| {
					vec![
						"issued".into(),
						Argument::Reference(root.clone()),
						intent.clone().into(),
						result,
						Argument::Void,
					]
				};
				let revision = host.send(&root, "snapshot", &[]).await.unwrap();
				host.send(&root, "settle-effect", &settle(outcome(actual.clone(), &uri)))
					.await
					.unwrap();
				assert_eq!(
					host.send(&root, "snapshot", &[]).await.unwrap().as_list().unwrap()[0],
					revision.as_list().unwrap()[0],
					"same exact outcome is a no-op"
				);
				let wrong = host.enliven(&other_uri).await.unwrap();
				assert!(
					host.send(&root, "settle-effect", &settle(outcome(wrong, &other_uri)))
						.await
						.is_err(),
					"equal data and coordinates cannot substitute another capability"
				);
				owner
					.import_result(&root, "issued", &intent, imported, imported)
					.await
					.unwrap();
				owner.import(imported, actual.clone(), Some(uri.clone())).await.unwrap();
				let before = host.send(&root, "snapshot", &[]).await.unwrap();
				owner.import(imported, actual, Some(uri.clone())).await.unwrap();
				assert_eq!(
					host.send(&root, "snapshot", &[]).await.unwrap(),
					before,
					"exact foreign import replay is a no-op"
				);
				assert!(
					owner
						.import(
							imported,
							host.enliven(&other_uri).await.unwrap(),
							Some(other_uri.clone())
						)
						.await
						.is_err()
				);

				assert_eq!(calls.get(), 1);
				if matches!(case, ResultCase::Stewardship) {
					let coordinate = &command_args[0];
					let snapshot = host.send(&root, "snapshot", &[]).await.unwrap();
					let revoke_base = snapshot.as_list().unwrap()[0].as_i64().unwrap();
					let mut revoke = args.clone();
					revoke[0] = "revoked".into();
					revoke[1] = revoke_base.into();
					revoke[4] = "revokeModerator".into();
					let revoke_intent = serde_json::to_string(&(
						"revoked",
						revoke_base,
						"operator",
						[coordinate.as_str(), "revokeModerator", "room"],
					))
					.unwrap();
					mutate(&host, &root, "command", &revoke).await.unwrap();
					assert_eq!(
						finished(&host, &root, "revoked", &root).await.as_str(),
						Some("committed")
					);
					let revoked = host
						.send(&root, "effect-result", &["revoked".into(), revoke_intent.into()])
						.await
						.unwrap();
					let revoked: session::results::Stewardship =
						serde_json::from_str(revoked.as_str().unwrap()).unwrap();
					assert!(
						revoked.steward.is_none(),
						"revocation result retains no issued authority"
					);
					assert_eq!(calls.get(), 2);
				}
				let completed_calls = calls.get();

				owner.close().await.unwrap();
				attachment.close().await.unwrap();
				dialed.close(PendingWork::Cancel).await.unwrap();
				accepted.close(PendingWork::Cancel).await.unwrap();
				host.close(PendingWork::Cancel).await.unwrap();
				drop(owner);
				environment::close(&mut store).await;
				drop(store);
				let mut store = database.open(false, &schemas, limits).await;
				let host = Host::from_seed([116; 32]).unwrap();
				let (dialed, accepted) = connect(&host, &exporter, &locator, gate::Gate::default()).await;
				let owner = managed::Session::new(
					host.clone(),
					Platform::default(),
					std::num::NonZeroUsize::new(4096).unwrap(),
				);
				let mut attachment = store
					.attach(&host, vec![owner.registration(), registration(&uri, &calls, case)])
					.unwrap();
				let (root, root_control) =
					environment::restore(&attachment, loam::Resource::decode(resource.encode())).await;
				owner.bind(root.clone(), root_control.clone()).unwrap();
				let (cold_data, actual) = disclosed(&host, &root, &intent, case).await;
				assert_eq!(actual, host.enliven(&uri).await.unwrap());
				assert_eq!(cold_data, data);
				let before = host.send(&root, "snapshot", &[]).await.unwrap();
				owner
					.import_result(&root, "issued", &intent, imported, imported)
					.await
					.unwrap();
				assert_eq!(
					host.send(&root, "snapshot", &[]).await.unwrap(),
					before,
					"cold result import compares original saved foreign authority without changing custody"
				);
				assert_eq!(
					mutate(&host, &root, "command", &args).await.unwrap().as_str(),
					Some("committed")
				);
				assert_eq!(
					calls.get(),
					completed_calls,
					"cold replay never dispatches issuance again"
				);
				owner.close().await.unwrap();
				attachment.close().await.unwrap();
				dialed.close(PendingWork::Cancel).await.unwrap();
				accepted.close(PendingWork::Cancel).await.unwrap();
				host.close(PendingWork::Cancel).await.unwrap();
				drop(owner);
				environment::close(&mut store).await;
				drop(store);
				exporter.close(PendingWork::Cancel).await.unwrap();
				database.remove();
			})
			.await
			.expect("typed result recovery makes bounded progress");
		})
		.await;
}
