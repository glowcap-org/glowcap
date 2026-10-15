//! Live posted-line custody survives interrupted private settlement and expires
//! at actual lifetime restart, including a target with a durable local recipe.
use super::*;
mod acquisition;
const SEAT: Schema = Schema {
	id: 0x534c495645303031,
	version: 1,
	max_payload: 64,
	max_edges: 2,
};

struct Seat {
	calls: Rc<Cell<usize>>,
	edits: Rc<Cell<usize>>,
	live_line: bool,
}
impl Content for Seat {
	fn requirement(&self, input: Invocation<'_>) -> Result<Requirement> {
		let required = if input.payload == b"line" {
			vec![rooms_application::content::permissions::Permission::InteractWorkspace.key()]
		} else {
			Vec::new()
		};
		Requirement::new(&required, &[])
	}
	fn references(&self, input: Invocation<'_>) -> Result<Vec<loam::ReferenceRequest>> {
		Ok(if input.verb == "configure-line" {
			let reference = Ref::try_from(&input.args[0]).unwrap();
			vec![if self.live_line {
				loam::ReferenceRequest::SaveLive(reference)
			} else {
				loam::ReferenceRequest::Save { reference, uri: None }
			}]
		} else if input.verb == rooms_application::room::correlation::POST {
			vec![loam::ReferenceRequest::Restore(0)]
		} else {
			Vec::new()
		})
	}
	fn invoke(&self, call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
		if input.payload == b"line" {
			match (input.verb, input.args) {
				("edit", [text]) if text.as_str() == Some("changed") => {}
				("withdraw", []) => {}
				_ => return Err(loam::refusal("unsupported line act")),
			}
			self.edits.set(self.edits.get() + 1);
			return Ok(Argument::Void);
		}
		assert_eq!(input.payload, b"seat");
		if input.verb == "configure-line" {
			call.append_reference(&Ref::try_from(&input.args[0]).unwrap())?;
			return Ok(Argument::Void);
		}
		assert_eq!(input.verb, rooms_application::room::correlation::POST);
		assert_eq!(input.args.len(), 3);
		assert_eq!(&input.args[..2], ["hello".into(), "[]".into()]);
		assert!(rooms_application::room::correlation::valid(
			input.args[2].as_str().unwrap()
		));
		self.calls.set(self.calls.get() + 1);
		Ok(Argument::List(vec![23.into(), call.disclose(0, false)?]))
	}
}
fn registration(calls: Rc<Cell<usize>>, edits: Rc<Cell<usize>>, live_line: bool) -> Registration {
	Registration {
		schema: SEAT.id,
		version: 1,
		graph: None,
		methods: vec![
			Method {
				verb: "edit".into(),
				retry: Retry::ReadOnly,
			},
			Method {
				verb: "withdraw".into(),
				retry: Retry::ReadOnly,
			},
			Method {
				verb: rooms_application::room::correlation::POST.into(),
				retry: Retry::ReadOnly,
			},
			Method {
				verb: "configure-line".into(),
				retry: Retry::Idempotent,
			},
		],
		content: Box::new(Seat {
			calls,
			edits,
			live_line,
		}),
	}
}
async fn command(host: &Host, source: &Ref, id: &str) -> (Vec<Argument>, String) {
	let snapshot = host.send(source, "snapshot", &[]).await.unwrap();
	let base = snapshot.as_list().unwrap()[0].as_i64().unwrap();
	let args = vec![
		id.into(),
		base.into(),
		"say".into(),
		"conversation".into(),
		"hello".into(),
	];
	let canonical = serde_json::to_string(&(id, base, "say", ["conversation", "hello"])).unwrap();
	(args, canonical)
}
async fn disclosed(host: &Host, source: &Ref, canonical: &str) -> (String, Ref) {
	let answer = host
		.send(source, "effect-result", &["posted".into(), canonical.into()])
		.await
		.unwrap();
	let [data, fields] = answer.as_list().unwrap() else {
		panic!("typed live result")
	};
	let data = data.as_str().unwrap().to_owned();
	let row: session::results::PostedLine = serde_json::from_str(&data).unwrap();
	assert_eq!(
		row.id.unwrap().get(),
		23,
		"result retains the server's notification identity"
	);
	let [field] = fields.as_list().unwrap() else {
		panic!("one exact line")
	};
	let [coordinate, reference] = field.as_list().unwrap() else {
		panic!("coordinate and line")
	};
	let coordinate: custody::Coordinate = serde_json::from_str(coordinate.as_str().unwrap()).unwrap();
	let key = row.line.unwrap();
	assert_eq!(coordinate.role, custody::Role::Line);
	assert_eq!(coordinate.key.slot(), key.slot());
	assert_eq!(coordinate.key.generation(), key.generation());
	(data, Ref::try_from(reference).unwrap())
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn posted_line_keeps_exact_live_result_through_settlement_and_refuses_after_restart() {
	run().await;
}

pub(super) async fn run() {
	for external in [false, true] {
		run_case(external).await;
	}
}
async fn run_case(external: bool) {
	tokio::task::LocalSet::new()
		.run_until(async {
			environment::within(10_000, async {
				let database = Database::new(if external {
					"external-live-line-result"
				} else {
					"live-line-result"
				});
				let mut schemas = managed::schemas();
				schemas.push(SEAT);
				// Source admission, dependent result checks and live-recipe reads
				// overlap on IndexedDB. Use the production profile's bounded
				// managed windows, as the direct-result journey does.
				let limits = managed::production_limits().unwrap();
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
				let seat_resource = environment::create(&store, &policy, SEAT, b"seat", 1).await;
				let replacement_resource = environment::create(&store, &policy, SEAT, b"seat", 4).await;
				let line_resource = environment::create(&store, &policy, SEAT, b"line", 2).await;
				let host = Host::from_seed([117; 32]).unwrap();
				let platform = Platform::default();
				let owner = managed::Session::new(
					host.clone(),
					platform.clone(),
					std::num::NonZeroUsize::new(4096).unwrap(),
				);
				let refuse = Rc::new(Cell::new(true));
				let mut content = owner.registration();
				content.content = Box::new(AbortAfterAdmission {
					inner: content.content,
					refuse: Rc::new(Cell::new(false)),
					refuse_settlement: refuse.clone(),
				});
				let calls = Rc::new(Cell::new(0));
				let edits = Rc::new(Cell::new(0));
				let mut attachment = store
					.attach(
						&host,
						vec![content, registration(calls.clone(), edits.clone(), external)],
					)
					.unwrap();
				let upstream_database = Database::new("live-line-upstream");
				let mut upstream_store = if external {
					Some(upstream_database.open(true, &schemas, limits).await)
				} else {
					None
				};
				let exporter = Host::from_seed([118; 32]).unwrap();
				let locator = glowcap::Locator::bare("tcp", "127.0.0.1:9011");
				exporter.set_advertised_locator(&locator).unwrap();
				let upstream_resource = if let Some(store) = &upstream_store {
					environment::create(store, &policy, SEAT, b"line", 2).await
				} else {
					line_resource
				};
				let mut upstream_attachment = upstream_store.as_ref().map(|store| {
					store
						.attach(&exporter, vec![registration(calls.clone(), edits.clone(), false)])
						.unwrap()
				});
				attachment.start_live(None, 32).unwrap();
				let (root, root_control) = environment::restore(&attachment, resource).await;
				owner.bind(root.clone(), root_control.clone()).unwrap();
				owner.initialize().await.unwrap();
				let (seat, _) = environment::restore(&attachment, seat_resource).await;
				let (line_root, _) =
					environment::restore(upstream_attachment.as_ref().unwrap_or(&attachment), upstream_resource).await;
				let upstream_terms = policy
					.value_for_kind(
						session::KIND,
						&[
							rooms_application::content::permissions::Permission::ObserveWorkspace.key(),
							rooms_application::content::permissions::Permission::InteractWorkspace.key(),
						],
						&[],
					)
					.unwrap();
				let upstream_host = if external { &exporter } else { &host };
				let derived = upstream_host
					.send(
						&line_root,
						"derive-managed",
						&upstream_terms.managed_derive_arguments(
							1,
							Scope::Object,
							1,
							ControlPowers {
								policy_ceiling: Some(upstream_terms),
								pause: true,
								resume: true,
								revoke: true,
								..Default::default()
							},
						),
					)
					.await
					.unwrap();
				let [line, upstream_control] = derived.as_list().unwrap() else {
					panic!("upstream use/control")
				};
				let line = Ref::try_from(line).unwrap();
				let upstream_control = Ref::try_from(upstream_control).unwrap();
				let mut connected = None;
				let line = if external {
					let held = line.clone();
					exporter
						.publish("line-disclosure", || {
							Box::new(move |verb, args| {
								assert_eq!(verb, "take");
								assert!(args.is_empty());
								Ok(Argument::Reference(held.clone()))
							})
						})
						.unwrap();
					let pair = super::results::connect(&host, &exporter, &locator, gate::Gate::default()).await;
					let disclosure = pair.0.fetch("line-disclosure").await.unwrap();
					let returned = host.send(&disclosure, "take", &[]).await.unwrap();
					connected = Some(pair);
					Ref::try_from(&returned).unwrap()
				} else {
					line
				};
				host.send(&seat, "configure-line", &[Argument::Reference(line.clone())])
					.await
					.unwrap();
				let coordinate = custody::Coordinate {
					role: custody::Role::RoomSeat,
					key: key(),
				};
				owner.import(coordinate, seat.clone(), None).await.unwrap();
				owner
					.import(
						custody::Coordinate {
							role: custody::Role::DirectoryAccess,
							key: key(),
						},
						seat.clone(),
						None,
					)
					.await
					.unwrap();
				let mut intent = Case::policy(false).workspace(1);
				let session::workspace::Conversation::Room(room) = &mut intent.conversations.as_mut_slice()[0] else {
					panic!("room")
				};
				room.control = None;
				room.seat = Some(key());
				owner.replace_workspace(&intent).await.unwrap();
				let terms = policy
					.value_for_kind(
						session::KIND,
						&[
							rooms_application::content::permissions::Permission::ObserveWorkspace.key(),
							rooms_application::content::permissions::Permission::InteractWorkspace.key(),
						],
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
				let (args, canonical) = command(&host, &source, "posted").await;
				assert_eq!(
					mutate(&host, &source, "command", &args).await.unwrap().as_str(),
					Some("pending")
				);
				assert_eq!(
					finished(&host, &root, "posted", &source).await.as_str(),
					Some("unknown")
				);
				assert_eq!(calls.get(), 1);
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
				refuse.set(false);
				owner.resume_pending().unwrap();
				let settled = finished(&host, &root, "posted", &source).await;
				if settled.as_str() != Some("committed") {
					panic!("private live result settlement failed: {:?}", owner.close().await);
				}
				assert!(
					host.send(&source, "effect-result", &["posted".into(), canonical.clone().into()])
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
				let (data, actual) = disclosed(&host, &source, &canonical).await;
				let reader = host
					.send(&source, "effect-reader", &["posted".into(), canonical.clone().into()])
					.await
					.unwrap();
				assert_eq!(
					host.send(
						&Ref::try_from(&reader).unwrap(),
						"read",
						&["posted".into(), source.clone().into()]
					)
					.await
					.unwrap()
					.as_str(),
					Some("committed")
				);
				let (replacement, _) = environment::restore(&attachment, replacement_resource).await;
				acquisition::run(&host, &owner, &root, &source, &canonical, seat, replacement).await;
				assert_ne!(actual, line, "public result is the saved dependent facet");
				assert_eq!(
					disclosed(&host, &source, &canonical).await.1,
					actual,
					"replay must preserve the actual facet"
				);
				host.send(&actual, "edit", &["changed".into()]).await.unwrap();
				assert_eq!(edits.get(), 1);
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
				assert!(host.send(&actual, "edit", &["changed".into()]).await.is_err());
				assert_eq!(edits.get(), 1);
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
				let observation = policy
					.value_for_kind(
						session::KIND,
						&[rooms_application::content::permissions::Permission::ObserveWorkspace.key()],
						&[],
					)
					.unwrap();
				host.send(
					&control,
					"mutate",
					&observation
						.set_policy_arguments(1, glowcap::loam::control_revision(&host, &control).await.unwrap()),
				)
				.await
				.unwrap();
				assert!(host.send(&actual, "edit", &["changed".into()]).await.is_err());
				assert_eq!(
					edits.get(),
					1,
					"current source policy governs an already disclosed line"
				);
				host.send(
					&control,
					"mutate",
					&terms.set_policy_arguments(2, glowcap::loam::control_revision(&host, &control).await.unwrap()),
				)
				.await
				.unwrap();
				upstream_host
					.send(
						&upstream_control,
						"pause",
						&[Argument::Bytes(
							glowcap::loam::control_revision(upstream_host, &upstream_control)
								.await
								.unwrap()
								.to_be_bytes()
								.to_vec(),
						)],
					)
					.await
					.unwrap();
				assert!(host.send(&actual, "edit", &["changed".into()]).await.is_err());
				assert_eq!(edits.get(), 1);
				upstream_host
					.send(
						&upstream_control,
						"resume",
						&[Argument::Bytes(
							glowcap::loam::control_revision(upstream_host, &upstream_control)
								.await
								.unwrap()
								.to_be_bytes()
								.to_vec(),
						)],
					)
					.await
					.unwrap();
				host.send(&actual, "withdraw", &[]).await.unwrap();
				assert_eq!(edits.get(), 2);
				let result_coordinate = serde_json::to_string(&custody::Coordinate {
					role: custody::Role::Line,
					key: key(),
				})
				.unwrap();
				let settle = |reference: Ref, recipe: Argument| {
					vec![
						"posted".into(),
						Argument::Reference(source.clone()),
						canonical.clone().into(),
						Argument::List(vec![
							data.clone().into(),
							Argument::List(vec![Argument::List(vec![
								result_coordinate.clone().into(),
								Argument::Reference(reference),
								recipe,
							])]),
						]),
						Argument::Void,
					]
				};
				let before = host.send(&root, "snapshot", &[]).await.unwrap();
				host.send(
					&root,
					"settle-effect",
					&settle(line.clone(), Argument::List(vec!["live".into()])),
				)
				.await
				.unwrap();
				assert_eq!(host.send(&root, "snapshot", &[]).await.unwrap(), before);
				assert!(
					host.send(&root, "settle-effect", &settle(line.clone(), Argument::Void))
						.await
						.is_err(),
					"absence of a URI cannot select live custody"
				);
				assert!(
					host.send(
						&root,
						"settle-effect",
						&settle(root.clone(), Argument::List(vec!["live".into()]))
					)
					.await
					.is_err(),
					"equal coordinates cannot substitute authority"
				);
				assert_eq!(calls.get(), 1);
				let (root_args, root_canonical) = command(&host, &root, "posted-root").await;
				mutate(&host, &root, "command", &root_args).await.unwrap();
				assert_eq!(
					finished(&host, &root, "posted-root", &root).await.as_str(),
					Some("committed")
				);
				assert_eq!(calls.get(), 2);
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
				assert!(host.send(&actual, "edit", &["changed".into()]).await.is_err());
				assert_eq!(edits.get(), 2);
				let marker = attachment.live_marker().unwrap().unwrap();
				owner.close().await.unwrap();
				attachment.close().await.unwrap();
				if let Some(upstream) = &mut upstream_attachment {
					upstream.close().await.unwrap();
				}
				if let Some((dialed, accepted)) = connected {
					dialed.close(PendingWork::Cancel).await.unwrap();
					accepted.close(PendingWork::Cancel).await.unwrap();
				}
				exporter.close(PendingWork::Cancel).await.unwrap();
				if let Some(store) = &mut upstream_store {
					environment::close(store).await;
				}
				drop(upstream_store);
				if external {
					upstream_database.remove();
				}
				host.close(PendingWork::Cancel).await.unwrap();
				drop(owner);
				environment::close(&mut store).await;
				drop(store);
				let mut reopened = database.open(false, &schemas, limits).await;
				let cold_host = Host::from_seed([117; 32]).unwrap();
				let cold_owner = managed::Session::new(
					cold_host.clone(),
					Platform::default(),
					std::num::NonZeroUsize::new(4096).unwrap(),
				);
				let mut cold_attachment = reopened.attach(&cold_host, vec![cold_owner.registration()]).unwrap();
				cold_attachment.start_live(Some(marker), 32).unwrap();
				let (cold_root, cold_root_control) =
					environment::restore(&cold_attachment, loam::Resource::decode(resource.encode())).await;
				cold_owner.bind(cold_root.clone(), cold_root_control.clone()).unwrap();
				let error = cold_host
					.send(
						&cold_root,
						"effect-result",
						&["posted-root".into(), root_canonical.into()],
					)
					.await
					.unwrap_err();
				assert_eq!(error.message(), Some("LiveReferenceExpired"));
				assert_eq!(
					finished(&cold_host, &cold_root, "posted-root", &cold_root)
						.await
						.as_str(),
					Some("committed")
				);
				let (fresh, _) = command(&cold_host, &cold_root, "fresh").await;
				assert!(
					mutate(&cold_host, &cold_root, "command", &fresh).await.is_err(),
					"expired seat cannot redirect a new post"
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
			.expect("live result custody has bounded progress");
		})
		.await;
}
