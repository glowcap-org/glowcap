//! Invitation entrances stay private; only the executor acquires membership.
use super::membership_results::{self as membership, MEMBER};
use super::publication_results::{coordinate, lifecycle};
use super::*;
use rooms_application::content::session::{results::Acceptance, workspace};

const INVITATION: Schema = Schema {
	id: 0x53494e5649544531,
	version: 1,
	max_payload: 64,
	max_edges: 2,
};
const RECEIPT: &str = "00112233445566778899aabbccddeeff";
struct Offer {
	claims: Rc<Cell<usize>>,
	malformed: bool,
}
impl Content for Offer {
	fn requirement(&self, _: Invocation<'_>) -> Result<Requirement> {
		Requirement::new(&[], &[])
	}
	fn references(&self, input: Invocation<'_>) -> Result<Vec<loam::ReferenceRequest>> {
		Ok(if input.verb == "claimInvitation" {
			vec![loam::ReferenceRequest::Restore(0)]
		} else {
			Vec::new()
		})
	}
	fn invoke(&self, call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
		match input.verb {
			"configure" => {
				call.append_reference(&Ref::try_from(&input.args[0]).unwrap())?;
				Ok(Argument::Void)
			}
			"claimInvitation" => {
				assert_eq!(input.payload, b"offer", "replacement cannot redirect the claim");
				assert_eq!(input.args, &[Argument::from(RECEIPT)]);
				self.claims.set(self.claims.get() + 1);
				if self.malformed {
					Ok(true.into())
				} else {
					call.disclose(0, false)
				}
			}
			_ => Err(loam::refusal("unsupported invitation fixture method")),
		}
	}
}
fn registration(claims: Rc<Cell<usize>>, malformed: bool) -> Registration {
	Registration {
		schema: INVITATION.id,
		version: 1,
		graph: None,
		methods: ["configure", "claimInvitation"]
			.into_iter()
			.map(|verb| Method {
				verb: verb.into(),
				retry: Retry::Idempotent,
			})
			.collect(),
		content: Box::new(Offer { claims, malformed }),
	}
}
async fn claim(host: &Host, source: &Ref, id: &str) -> (Vec<Argument>, String) {
	let base = host.send(source, "snapshot", &[]).await.unwrap().as_list().unwrap()[0]
		.as_i64()
		.unwrap();
	let canonical = serde_json::to_string(&(id, base, "acceptInvitation", ["invitation", RECEIPT])).unwrap();
	(
		vec![
			id.into(),
			base.into(),
			"acceptInvitation".into(),
			"invitation".into(),
			RECEIPT.into(),
		],
		canonical,
	)
}
async fn acceptance(host: &Host, source: &Ref, canonical: &str) {
	let answer = host
		.send(source, "effect-result", &["accepted".into(), canonical.into()])
		.await
		.unwrap();
	let [data, fields] = answer.as_list().unwrap() else {
		panic!("typed acceptance result")
	};
	let row: Acceptance = serde_json::from_str(data.as_str().unwrap()).unwrap();
	assert_eq!(row.entrance, key());
	assert!(
		fields.as_list().unwrap().is_empty(),
		"no raw entrance may escape to subscribe outside mediation"
	);
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn accepted_invitation_is_private_exact_live_custody_and_only_yields_mediated_membership() {
	run().await;
}
pub(super) async fn run() {
	for malformed in [false, true] {
		run_case(malformed).await;
	}
}
async fn run_case(malformed: bool) {
	tokio::task::LocalSet::new()
		.run_until(async {
			environment::within(10_000, async {
				let database = Database::new(if malformed {
					"invitation-malformed"
				} else {
					"invitation-acquisition"
				});
				let mut schemas = managed::schemas();
				schemas.extend([INVITATION, MEMBER]);
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
				// Two endpoints per resource, plus three public sources and their controls.
				limits.max_references = 2 * (1 + 7 + 3);
				limits.max_retentions = 24 + limits.max_references;
				let mut store = database.open(true, &schemas, limits).await;
				let policy = rooms_glowcap::policy::descriptor().unwrap();
				let resource =
					environment::create(&store, &policy, schemas[0], &managed::initial_payload(rooms_application::content::session::workspace::Connection::Relay).unwrap(), 3).await;
				let offer_resource = environment::create(&store, &policy, INVITATION, b"offer", 2).await;
				let mut resources = Vec::new();
				for payload in [
					b"entrance".as_slice(),
					b"seat",
					b"topic",
					b"files",
					b"inbox",
					b"replacement",
				] {
					resources.push(environment::create(&store, &policy, MEMBER, payload, 2).await);
				}
				let host = Host::from_seed([124; 32]).unwrap();
				let platform = Platform::default();
				let owner = managed::Session::new(
					host.clone(),
					platform.clone(),
					std::num::NonZeroUsize::new(4096).unwrap(),
				);
				let claims = Rc::new(Cell::new(0));
				let joins = Rc::new(Cell::new(0));
				let acts = Rc::new(Cell::new(0));
				let refuse = Rc::new(Cell::new(true));
				let mut content = owner.registration();
				content.content = Box::new(AbortAfterAdmission {
					inner: content.content,
					refuse: Rc::new(Cell::new(false)),
					refuse_settlement: refuse.clone(),
				});
				let mut attachment = store
					.attach(
						&host,
						vec![
							content,
							registration(claims.clone(), malformed),
							membership::registration(joins.clone(), acts.clone(), Rc::new(Cell::new(0)), 3),
						],
					)
					.unwrap();
				attachment.start_live(None, 64).unwrap();
				let (root, root_control) = environment::restore(&attachment, resource).await;
				owner.bind(root.clone(), root_control.clone()).unwrap();
				owner.initialize().await.unwrap();
				let (offer, _) = environment::restore(&attachment, offer_resource).await;
				let mut held = Vec::new();
				for resource in resources {
					held.push(environment::restore(&attachment, resource).await.0);
				}
				host.send(&offer, "configure", &[Argument::Reference(held[0].clone())])
					.await
					.unwrap();
				host.send(
					&held[0],
					"configure",
					&held[1..4].iter().cloned().map(Argument::Reference).collect::<Vec<_>>(),
				)
				.await
				.unwrap();
				for (role, reference) in [
					(custody::Role::Offer, &offer),
					(custody::Role::DirectoryAccess, &held[0]),
					(custody::Role::RoomInbox, &held[4]),
				] {
					owner
						.import(coordinate(role, 1), reference.clone(), None)
						.await
						.unwrap();
				}
				let mut intent = Case::kick().workspace(1);
				let workspace::Conversation::Room(room) = &mut intent.conversations.as_mut_slice()[0] else {
					panic!("room")
				};
				room.moderator = None;
				room.access = None;
				room.reconnect = session::workspace::Reconnect::Manual;
				intent.invitations = serde_json::from_value(serde_json::json!([{
				"id": "invitation", "directory": "directory", "label": "room", "from": "peer", "authority":{"role":"offer","key":key::<custody::Offer>()}
				}]))
				.unwrap();
				owner.replace_workspace(&intent).await.unwrap();
				let terms = policy
					.value_for_kind(
						session::KIND,
						&session::SUPPORTED.iter().map(|p| p.key()).collect::<Vec<_>>(),
						&[],
					)
					.unwrap();
				let powers = ControlPowers {
					policy_ceiling: Some(terms),
					pause: true,
					resume: true,
					revoke: true,
					..Default::default()
				};
				let (source, control) = owner.derive(terms, 1, powers).await.unwrap();
				let (other, _) = owner.derive(terms, 1, ControlPowers::default()).await.unwrap();
				let (args, canonical) = claim(&host, &source, "accepted").await;
				let limited = policy
					.value_for_kind(
						session::KIND,
						&session::SUPPORTED
							.iter()
							.filter(|p| !matches!(**p, rooms_application::content::permissions::Permission::ManageCustody | rooms_application::content::permissions::Permission::ShareCustody))
							.map(|p| p.key())
							.collect::<Vec<_>>(),
						&[],
					)
					.unwrap();
				let (no_import, _) = owner.derive(limited, 1, ControlPowers::default()).await.unwrap();
				assert!(
					mutate(&host, &no_import, "command", &args).await.is_err(),
					"claim acquisition requires ManageCustody before it can dispatch"
				);
				assert_eq!(claims.get(), 0);
				platform.suspended.set(true);
				assert_eq!(
					mutate(&host, &source, "command", &args).await.unwrap().as_str(),
					Some("pending")
				);
				assert_eq!(claims.get(), 0);
				intent.invitations = List::default();
				owner.replace_workspace(&intent).await.unwrap();
				platform.suspended.set(false);
				assert_eq!(
					finished(&host, &root, "accepted", &source).await.as_str(),
					Some("unknown")
				);
				assert_eq!(claims.get(), 1);
				if !malformed {
					lifecycle(&host, &control, "pause").await;
					refuse.set(false);
					owner.resume_pending().unwrap();
					assert_eq!(
						finished(&host, &root, "accepted", &source).await.as_str(),
						Some("committed")
					);
					assert!(
						host.send(&source, "effect-result", &["accepted".into(), canonical.clone().into()])
							.await
							.is_err()
					);
					lifecycle(&host, &control, "resume").await;
					acceptance(&host, &source, &canonical).await;
					let entrance = coordinate(custody::Role::AcceptedAccess, 1);
					assert!(
						owner
							.import_result(&other, "accepted", &canonical, entrance, entrance)
							.await
							.is_err()
					);
					assert!(
						owner
							.import_result(
								&source,
								"accepted",
								&canonical,
								entrance,
								coordinate(custody::Role::RoomAccess, 1)
							)
							.await
							.is_err()
					);
					owner
						.import_result(&source, "accepted", &canonical, entrance, entrance)
						.await
						.unwrap();
					let workspace::Conversation::Room(room) = &mut intent.conversations.as_mut_slice()[0] else {
						panic!("room")
					};
					room.accepted = Some(key());
					room.inbox = Some(key());
					owner.replace_workspace(&intent).await.unwrap();
					let (joined, join_canonical) = membership::command(&host, &source, "joined", 1).await;
					mutate(&host, &source, "command", &joined).await.unwrap();
					assert_eq!(
						finished(&host, &root, "joined", &source).await.as_str(),
						Some("committed")
					);
					assert_eq!(joins.get(), 1);
					let (_, members) = membership::disclose(&host, &source, "joined", &join_canonical).await;
					assert_ne!(members[0], held[1]);
					host.send(&members[0], "typing", &[true.into()]).await.unwrap();
					assert_eq!(acts.get(), 1);
					lifecycle(&host, &control, "pause").await;
					assert!(host.send(&members[0], "typing", &[true.into()]).await.is_err());
					assert_eq!(acts.get(), 1);
					lifecycle(&host, &control, "resume").await;
					assert_eq!(
						mutate(&host, &source, "command", &args).await.unwrap().as_str(),
						Some("committed")
					);
					assert_eq!(claims.get(), 1);
					// Root acceptance supplies cold-expiry evidence independently of the revoked source.
					intent.invitations = serde_json::from_value(serde_json::json!([{
					"id": "invitation", "directory": "directory", "label": "room", "from": "peer", "authority":{"role":"offer","key":key::<custody::Offer>()}
					}]))
					.unwrap();
					owner.replace_workspace(&intent).await.unwrap();
					let (cold_args, cold_canonical) = claim(&host, &root, "cold").await;
					mutate(&host, &root, "command", &cold_args).await.unwrap();
					assert_eq!(finished(&host, &root, "cold", &root).await.as_str(), Some("committed"));
					lifecycle(&host, &control, "revoke").await;
					assert!(host.send(&members[0], "typing", &[true.into()]).await.is_err());
					assert_eq!(acts.get(), 1);
					let marker = attachment.live_marker().unwrap().unwrap();
					owner.close().await.unwrap();
					attachment.close().await.unwrap();
					host.close(PendingWork::Cancel).await.unwrap();
					drop(owner);
					environment::close(&mut store).await;
					drop(store);
					let mut cold_store = database.open(false, &schemas, limits).await;
					let cold_host = Host::from_seed([124; 32]).unwrap();
					let cold_owner = managed::Session::new(
						cold_host.clone(),
						Platform::default(),
						std::num::NonZeroUsize::new(4096).unwrap(),
					);
					let mut cold_attachment = cold_store.attach(&cold_host, vec![cold_owner.registration()]).unwrap();
					cold_attachment.start_live(Some(marker), 64).unwrap();
					let (cold_root, cold_root_control) = environment::restore(&cold_attachment, resource).await;
					cold_owner.bind(cold_root.clone(), cold_root_control.clone()).unwrap();
					assert_eq!(
						finished(&cold_host, &cold_root, "cold", &cold_root).await.as_str(),
						Some("committed")
					);
					assert!(
						cold_owner
							.import_result(
								&cold_root,
								"cold",
								&cold_canonical,
								entrance,
								coordinate(custody::Role::AcceptedAccess, 9)
							)
							.await
							.is_err()
					);
					assert_eq!(
						mutate(&cold_host, &cold_root, "command", &cold_args)
							.await
							.unwrap()
							.as_str(),
						Some("committed")
					);
					cold_owner.close().await.unwrap();
					cold_attachment.close().await.unwrap();
					cold_host.close(PendingWork::Cancel).await.unwrap();
					drop(cold_owner);
					environment::close(&mut cold_store).await;
					drop(cold_store);
					database.remove();
				} else {
					refuse.set(false);
					owner.resume_pending().unwrap();
					assert_eq!(finished(&host, &root, "accepted", &source).await.as_str(), Some("unknown"));
					let value = host.send(&source, "effect-result", &["accepted".into(), canonical.into()]).await.unwrap();
					unknown_reason(&value);
					assert_eq!(claims.get(), 1);
					owner.close().await.unwrap();
					attachment.close().await.unwrap();
					host.close(PendingWork::Cancel).await.unwrap();
					drop(owner);
					environment::close(&mut store).await;
					drop(store);
					database.remove();
				}
			})
			.await
			.expect("invitation acquisition has bounded progress");
		})
		.await;
}
