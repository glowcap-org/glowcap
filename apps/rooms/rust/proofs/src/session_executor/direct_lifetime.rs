//! Exporter loss retires the exact saved DM, including failed startup and expiry.
use super::*;
use rooms_application::content::session::workspace::{self, Conversation};
use rooms_glowcap::client::workspace::Workspace;

#[derive(Clone, Copy)]
enum Boundary {
	Ready,
	FailedReady,
	PausedExpiry,
	QueryPressure,
}

#[tokio::test]
async fn direct_exporter_loss_closes_the_saved_route_without_a_local_close() {
	run(Boundary::Ready).await;
}

#[tokio::test]
async fn direct_exporter_loss_is_observed_after_failed_readiness() {
	run(Boundary::FailedReady).await;
}

#[tokio::test]
async fn direct_exporter_loss_survives_a_refused_workspace_expiry() {
	run(Boundary::PausedExpiry).await;
}

#[tokio::test]
async fn direct_retirement_is_independent_of_public_query_debt() {
	run(Boundary::QueryPressure).await;
}

async fn run(boundary: Boundary) {
	tokio::task::LocalSet::new()
		.run_until(async {
			environment::within(10_000, async {
				let database = Database::new("direct-lifetime");
				let schemas = managed::schemas();
				let mut limits = crate::session_storage::limits_for(
					24,
					8,
					loam::ValueBounds {
						values: 512,
						capabilities: 8,
						bytes: 65536,
						..Default::default()
					},
				);
				limits.pending_bytes = limits.call_bytes * limits.max_operations;
				limits.ingress_bytes = limits.pending_bytes;
				limits.cache_slots = 3 * (limits.record_capacity + 2) + 5;
				limits.resident_bytes = limits.cache_slots * limits.record_bytes;
				limits.max_leases = limits.cache_slots * limits.max_operations;
				limits.max_references = 32;
				let mut store = database.open(true, &schemas, limits).await;
				let policy = rooms_glowcap::policy::descriptor().unwrap();
				let resource = environment::create(
					&store,
					&policy,
					schemas[0],
					&managed::initial_payload(workspace::Connection::Relay).unwrap(),
					3,
				)
				.await;
				let host = Host::from_seed([191; 32]).unwrap();
				let exporter = Host::from_seed([192; 32]).unwrap();
				let platform = Platform::default();
				let owner = managed::Session::new(
					host.clone(),
					platform.clone(),
					std::num::NonZeroUsize::new(65536).unwrap(),
				);
				if matches!(boundary, Boundary::QueryPressure) {
					owner
						.configure_admission(
							rooms_application::admission::Settings::parse(
								|key| (key == "admission-rates").then(|| "read=64/64".into()),
								4096,
								8,
							)
							.unwrap(),
						)
						.unwrap();
				}
				let mut attachment = store.attach(&host, vec![owner.registration()]).unwrap();
				environment::start_live(&attachment, None, 64).await;
				let (root, root_control) = environment::restore(&attachment, resource).await;
				owner.bind(root.clone(), root_control).unwrap();
				owner.initialize().await.unwrap();
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
							pause: true,
							resume: true,
							..Default::default()
						},
					)
					.await
					.unwrap();
				let announced = Rc::new(Cell::new(0));
				let announcements = announced.clone();
				exporter
					.publish("peer", move || {
						let announcements = announcements.clone();
						Box::new(move |verb, _| {
							let verb = verb.ok_or("fixture requires a method")?;
							assert_eq!(verb, rooms_application::direct::READY);
							announcements.set(announcements.get() + 1);
							if matches!(boundary, Boundary::FailedReady) {
								Err("peer refused readiness".into())
							} else {
								Ok(Argument::Void)
							}
						})
					})
					.unwrap();
				let locator = glowcap::Locator::bare("tcp", "127.0.0.1:9147");
				let (left, right) = tokio::io::duplex(4096);
				let (importer, remote) = tokio::join!(
					glowcap::Session::dial_over(&host, &locator, left, Some(std::time::Duration::from_secs(2))),
					glowcap::Session::accept_over(
						&exporter,
						"tcp",
						"127.0.0.1:9147",
						"127.0.0.1:9146",
						right,
						Some(std::time::Duration::from_secs(2))
					),
				);
				let (importer, remote) = (importer.unwrap(), remote.unwrap());
				let inbox = importer.fetch("peer").await.unwrap();
				let sibling = host.spawn(|_, _| Ok(Argument::Void)).unwrap();
				for (role, slot, reference) in [
					(custody::Role::SessionAccess, 1, source.clone()),
					(custody::Role::DirectoryAccess, 1, root.clone()),
					(custody::Role::DirectAccess, 1, inbox),
					(custody::Role::DirectAccess, 2, sibling),
				] {
					owner
						.import(requests::coordinate(role, slot), reference, None)
						.await
						.unwrap();
				}
				let mut intent = Intent::empty();
				intent.directories = List::new(vec![workspace::Directory {
					id: rooms_application::fields::Text::new("directory".into()).unwrap(),
					access: key(),
					name: None,
					source: None,
					inbox: None,
					home: true,
					nick: rooms_application::fields::Text::new("self".into()).unwrap(),
					assigned_nick: None,
					nick_allocation: rooms_application::directory::registration::NicknameAllocation::Exact,
					standing: None,
				}])
				.unwrap();
				intent.conversations = List::new(
					[("direct", 1), ("sibling", 2)]
						.into_iter()
						.map(|(id, slot)| {
							Conversation::Direct(Box::new(workspace::Direct {
								kind: workspace::DirectKind::Direct,
								id: rooms_application::fields::Text::new(id.into()).unwrap(),
								directory: rooms_application::fields::Text::new("directory".into()).unwrap(),
								peer: rooms_application::fields::Text::new(id.into()).unwrap(),
								source: Some(key()),
								access: Some(custody::FieldKey::new(
									NonZeroU64::new(slot).unwrap(),
									NonZeroU64::new(1).unwrap(),
								)),
								inbox: None,
								introduction: None,
								closed: false,
								lines: List::default(),
								draft: rooms_application::fields::Text::new("preserved draft".into()).unwrap(),
							}))
						})
						.collect(),
				)
				.unwrap();
				owner.replace_workspace(&intent).await.unwrap();
				let Conversation::Direct(row) = &intent.conversations.as_slice()[0] else {
					unreachable!()
				};
				let mut membership = owner
					.supervise_direct(row, &mut realization::Entropy::seeded(193), |_, _, _, _| {
						Ok(Argument::Void)
					})
					.await
					.unwrap();
				let readiness = membership.ready().await;
				assert_eq!(
					readiness.is_err(),
					matches!(boundary, Boundary::FailedReady),
					"{readiness:?}"
				);
				assert_eq!(announced.get(), 1, "the peer received the actual readiness call");
				if matches!(boundary, Boundary::QueryPressure) {
					let querying = Workspace::local(host.clone(), platform.clone(), source.clone());
					let refusal = loop {
						if let Err(refusal) = querying.snapshot().await {
							break refusal;
						}
					};
					assert_eq!(
						rooms_application::failure::Failure::parse(&refusal.to_string())
							.unwrap()
							.retry_advice()
							.unwrap()
							.class,
						rooms_application::admission::Class::Read
					);
					assert!(
						host.send(
							&source,
							"continue-workspace",
							&[
								source.clone().into(),
								rooms_application::content::session::continuing::Method::Snapshot
									.wire()
									.into()
							]
						)
						.await
						.is_err(),
						"a collaborator cannot forge the private root witness"
					);
				}
				if matches!(boundary, Boundary::PausedExpiry) {
					publication_results::lifecycle(&host, &control, "pause").await;
				}
				remote.close(PendingWork::Cancel).await.unwrap();
				if matches!(boundary, Boundary::PausedExpiry) {
					assert!(membership.ended().await.is_err());
					assert!(membership.is_active(), "refused expiry retains its worker");
					publication_results::lifecycle(&host, &control, "resume").await;
					membership.close().await.unwrap();
				}
				membership.ended().await.unwrap();
				assert!(!membership.is_active());
				let snapshot = Workspace::local(host.clone(), platform, root).snapshot().await.unwrap();
				let Conversation::Direct(row) = &snapshot.intent.conversations.as_slice()[0] else {
					unreachable!()
				};
				assert!(row.closed);
				assert!(row.access.is_none() && row.inbox.is_none());
				assert_eq!(row.draft.text().as_str(), Some("preserved draft"));
				let Conversation::Direct(sibling) = &snapshot.intent.conversations.as_slice()[1] else {
					unreachable!()
				};
				assert!(!sibling.closed && sibling.access.is_some());
				owner.close().await.unwrap();
				attachment.close().await.unwrap();
				host.close(PendingWork::Cancel).await.unwrap();
				exporter.close(PendingWork::Cancel).await.unwrap();
				environment::close(&mut store).await;
				database.remove();
			})
			.await
			.expect("direct lifetime has bounded progress");
		})
		.await;
}
