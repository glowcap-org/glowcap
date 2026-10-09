//! Rooms consumes shared controls and bounded inventory on both physical stores.
use super::*;
use glowcap::loam::{AccessStatus, ControlDescription, UseDescription};
use rooms_glowcap::client::{
	Client,
	access::{Control, Issuance},
};

pub(super) async fn revision(control: &Control<Platform>) -> u64 {
	let state = control.describe().await.unwrap();
	let ControlDescription::Available(view) = state.view() else {
		panic!("available held management")
	};
	view.revision
}
pub(super) async fn connect(host: &Host, viewer: &Host, control: &Ref) -> (Client<Platform>, glowcap::Session) {
	host.publish("management-bootstrap", {
		let control = control.clone();
		move || {
			let control = control.clone();
			Box::new(move |verb, args| {
				if verb != "get" || !args.is_empty() {
					return Err("invalid owner bootstrap".into());
				}
				Ok(Argument::Reference(control.clone()))
			})
		}
	})
	.unwrap();
	let locator = glowcap::Locator::bare("tcp", "127.0.0.1:9149");
	let (left, right) = tokio::io::duplex(8192);
	let (imported, accepted) = tokio::join!(
		glowcap::Session::dial_over(viewer, &locator, left, Some(std::time::Duration::from_secs(2))),
		glowcap::Session::accept_over(
			host,
			"tcp",
			"127.0.0.1:9149",
			"127.0.0.1:9148",
			right,
			Some(std::time::Duration::from_secs(2))
		)
	);
	(Client::new(imported.unwrap(), Platform::default()), accepted.unwrap())
}
pub(super) async fn bootstrap(client: &Client<Platform>) -> Control<Platform> {
	let bootstrap = client.session().fetch("management-bootstrap").await.unwrap();
	let reference = client.session().send(&bootstrap, "get", &[]).await.unwrap();
	Control::new(client.clone(), Ref::try_from(&reference).unwrap())
}
fn all(policy: &loam::Policy) -> loam::PolicyValue {
	policy
		.value(
			&session::SUPPORTED
				.iter()
				.map(|permission| permission.key())
				.collect::<Vec<_>>(),
			&[],
		)
		.unwrap()
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn typed_management_keeps_powers_revisions_and_scoped_inventory_through_restart() {
	run().await;
}
pub(super) async fn run() {
	tokio::task::LocalSet::new()
		.run_until(async {
			environment::within(10_000, async {
				let database = Database::new("management");
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
				limits.max_leases *= limits.max_operations;
				// Sharing::advance overlaps the issuer, returned use and returned
				// control operations during cold replay. Each has a model window,
				// descriptor and directory scratch. The enclosing endpoint and
				// four retained receipt/publication/endpoint rows stay held too.
				// Control publication discovery retires before its managed window.
				limits.cache_slots = 3 * (limits.record_capacity + 2) + 5;
				limits.resident_bytes = limits.cache_slots * limits.record_bytes;
				let mut store = database.open(true, &schemas, limits).await;
				let policy = rooms_glowcap::policy::descriptor().unwrap();
				let wide = all(&policy);
				let observer = policy
					.value(
						&[rooms_application::content::permissions::Permission::ObserveWorkspace.key()],
						&[],
					)
					.unwrap();
				let empty = policy.value(&[], &[]).unwrap();
				let resource = environment::create(
					&store,
					&policy,
					schemas[0],
					&managed::initial_payload(rooms_application::content::session::workspace::Connection::Relay)
						.unwrap(),
					4,
				)
				.await;
				let host = Host::from_seed([121; 32]).unwrap();
				let viewer = Host::from_seed([122; 32]).unwrap();
				let owner = managed::Session::new(
					host.clone(),
					Platform::default(),
					std::num::NonZeroUsize::new(65536).unwrap(),
				);
				let mut attachment = store.attach(&host, vec![owner.registration()]).unwrap();
				let (root, root_control) = environment::restore(&attachment, resource).await;
				owner.bind(root, root_control.clone()).unwrap();
				owner.initialize().await.unwrap();
				let (client, accepted) = connect(&host, &viewer, &root_control).await;
				let management = bootstrap(&client).await;
				let powers = ControlPowers {
					inspect: true,
					issue_ceiling: Some(wide),
					policy_ceiling: Some(wide),
					delegate_control: true,
					pause: true,
					resume: true,
					revoke: true,
				};
				let request = Issuance::new(
					wide.with_ceiling(wide),
					management.derivation_sequence().await.unwrap(),
					revision(&management).await,
					2,
					powers,
					"main",
					false,
				);
				let issued = management.issue(&request).await.unwrap();
				let name = client
					.session()
					.send(&issued.access, "durable-name", &[])
					.await
					.unwrap();
				let child_management = Control::new(client.clone(), issued.control.clone());
				let control_name = child_management.durable_name().await.unwrap();
				assert_ne!(name.as_str().unwrap(), control_name);
				assert_eq!(client.session().fetch(&control_name).await.unwrap(), issued.control);
				let inspected = child_management.inspect().await.unwrap();
				assert_eq!(inspected.view().label, "main");
				let effective = child_management.inspect_fixed_access().await.unwrap();
				let UseDescription::Active(active) = effective.view() else {
					panic!("active inspected use")
				};
				assert_eq!(active.effective.permissions().count(), session::SUPPORTED.len());
				assert_eq!(
					inspected.view().configured.permissions().count(),
					session::SUPPORTED.len()
				);
				let snapshot = child_management.describe().await.unwrap();
				let ControlDescription::Available(view) = snapshot.view() else {
					panic!("available child control")
				};
				assert!(view.inspect && view.pause && view.resume && view.revoke && view.delegate_control);
				assert_eq!(
					view.issue_ceiling.unwrap().permissions().count(),
					session::SUPPORTED.len()
				);
				assert_eq!(
					view.edit_ceiling.unwrap().permissions().count(),
					session::SUPPORTED.len()
				);
				child_management.pause(view.revision).await.unwrap();
				assert!(matches!(
					child_management.inspect_fixed_access().await.unwrap().view(),
					UseDescription::Paused
				));
				let inspected = child_management.inspect().await.unwrap();
				assert_eq!(inspected.view().status, AccessStatus::Paused);
				assert_eq!(
					inspected.view().configured.permissions().count(),
					session::SUPPORTED.len()
				);
				let first_request = Issuance::new(
					observer.with_ceiling(observer),
					1,
					revision(&child_management).await,
					0,
					ControlPowers::default(),
					"first",
					false,
				);
				let first = child_management.issue(&first_request).await.unwrap();
				assert!(
					Control::new(client.clone(), first.control.clone())
						.inspect_fixed_access()
						.await
						.is_err(),
					"inspection requires its independently held power"
				);
				let second_request = Issuance::new(
					observer.with_ceiling(wide),
					2,
					revision(&child_management).await,
					0,
					ControlPowers {
						inspect: true,
						policy_ceiling: Some(wide),
						..Default::default()
					},
					"second",
					false,
				);
				let second = child_management.issue(&second_request).await.unwrap();
				let editable = Control::new(client.clone(), second.control);
				assert_eq!(
					editable
						.inspect()
						.await
						.unwrap()
						.view()
						.configured
						.permissions()
						.count(),
					1
				);
				editable.set_policy(1, revision(&editable).await, wide).await.unwrap();
				assert_eq!(
					editable
						.inspect()
						.await
						.unwrap()
						.view()
						.configured
						.permissions()
						.count(),
					session::SUPPORTED.len()
				);
				editable
					.set_policy(2, revision(&editable).await, observer)
					.await
					.unwrap();
				let page = child_management.inventory(None, 1).await.unwrap();
				let view = page.view();
				assert_eq!(view.rows().len(), 1);
				let row = view.rows().next().unwrap();
				assert_eq!(row.label, "first");
				assert_eq!(row.status, AccessStatus::Active);
				assert_eq!(row.effective_status, AccessStatus::Paused);
				assert_eq!(
					row.configured.permissions().collect::<Vec<_>>(),
					vec![rooms_application::content::permissions::Permission::ObserveWorkspace.key()]
				);
				let cursor = view.cursor.unwrap();
				let next_page = child_management.inventory(Some(cursor), 1).await.unwrap();
				assert_eq!(next_page.view().rows().next().unwrap().label, "second");
				// A full page stops before the next index read. Exhaustion is
				// confirmed by a subsequent empty page, not guessed from its size.
				let terminal = child_management.inventory(next_page.view().cursor, 1).await.unwrap();
				assert_eq!(terminal.view().rows().len(), 0);
				assert!(terminal.view().cursor.is_none());
				let old_revision = revision(&child_management).await;
				child_management.set_label(1, old_revision, "renamed").await.unwrap();
				child_management.set_label(1, old_revision, "renamed").await.unwrap();
				assert!(child_management.set_label(2, old_revision, "stale").await.is_err());
				assert!(child_management.inventory(Some(cursor), 1).await.is_err());
				child_management
					.set_policy(2, revision(&child_management).await, empty)
					.await
					.unwrap();
				let state = child_management.describe().await.unwrap();
				let ControlDescription::Available(view) = state.view() else {
					panic!("paused management stays available")
				};
				assert_eq!(view.status, AccessStatus::Paused);
				child_management.resume(view.revision).await.unwrap();
				assert!(client.session().send(&first.access, "snapshot", &[]).await.is_err());
				let third_request = Issuance::new(
					observer.with_ceiling(observer),
					3,
					revision(&child_management).await,
					0,
					ControlPowers::default(),
					"while narrowed",
					false,
				);
				child_management.issue(&third_request).await.unwrap();
				child_management
					.set_policy(3, revision(&child_management).await, observer)
					.await
					.unwrap();
				assert!(client.session().send(&first.access, "snapshot", &[]).await.is_ok());
				let replay = management.issue(&request).await.unwrap();
				assert_eq!(replay.access, issued.access);
				assert_eq!(replay.control, issued.control);
				let inspector_reference = child_management
					.attenuate(
						4,
						ControlPowers {
							inspect: true,
							..Default::default()
						},
					)
					.await
					.unwrap();
				let inspector = Control::new(client.clone(), inspector_reference);
				let inspector_name = inspector.durable_name().await.unwrap();
				assert_ne!(inspector_name, control_name);
				let state = inspector.describe().await.unwrap();
				let ControlDescription::Available(view) = state.view() else {
					panic!("inspector available")
				};
				assert!(view.inspect);
				assert!(view.issue_ceiling.is_none() && view.edit_ceiling.is_none());
				assert!(!view.pause && !view.resume && !view.revoke && !view.delegate_control);
				assert_eq!(inspector.inventory(None, 32).await.unwrap().view().rows().len(), 3);
				assert!(inspector.issue(&third_request).await.is_err());
				assert!(inspector.set_label(1, view.revision, "forbidden").await.is_err());
				assert!(inspector.pause(view.revision).await.is_err());
				assert_eq!(inspector.inspect().await.unwrap().view().label, "renamed");
				management
					.set_policy(
						management.mutation_sequence().await.unwrap(),
						revision(&management).await,
						empty,
					)
					.await
					.unwrap();
				let effective = inspector.inspect_fixed_access().await.unwrap();
				let UseDescription::Active(active) = effective.view() else {
					panic!("ancestor restriction preserves active inspection")
				};
				assert_eq!(
					active.configured.permissions().collect::<Vec<_>>(),
					vec![rooms_application::content::permissions::Permission::ObserveWorkspace.key()]
				);
				assert_eq!(
					active.effective.permissions().count(),
					0,
					"the shared evaluator includes ancestor restrictions"
				);
				assert!(
					client
						.session()
						.send(inspector.reference(), "snapshot", &[])
						.await
						.is_err(),
					"inspection confers no resource use"
				);
				management
					.set_policy(
						management.mutation_sequence().await.unwrap(),
						revision(&management).await,
						wide,
					)
					.await
					.unwrap();
				let pause_sequence = child_management.mutation_sequence().await.unwrap();
				let pause_revision = revision(&child_management).await;
				let pause = child_management.prepare_pause(pause_revision).await.unwrap();
				pause.submit().await.unwrap();
				let paused_revision = revision(&child_management).await;
				assert!(
					child_management.pause(pause_revision).await.is_err(),
					"fresh revision calls cannot recover a lost acknowledgment"
				);
				pause.submit().await.unwrap();
				assert_eq!(revision(&child_management).await, paused_revision);
				let resume = child_management.prepare_resume(paused_revision).await.unwrap();
				resume.submit().await.unwrap();
				let resumed_revision = revision(&child_management).await;
				resume.submit().await.unwrap();
				pause.submit().await.unwrap();
				assert_eq!(
					revision(&child_management).await,
					resumed_revision,
					"replaying a pause cannot pause a resumed grant"
				);
				assert_eq!(
					child_management.inspect().await.unwrap().view().status,
					AccessStatus::Active
				);
				let stale = child_management.prepare_pause(paused_revision).await.unwrap();
				assert!(
					stale.submit().await.is_err(),
					"a fresh prepared operation still checks revision"
				);
				let denied = inspector.prepare_pause(resumed_revision).await.unwrap();
				assert!(
					denied.submit().await.is_err(),
					"a prepared request retains its actual control powers"
				);
				drop((pause, resume, stale, denied));
				owner.close().await.unwrap();
				attachment.close().await.unwrap();
				viewer.close(PendingWork::Cancel).await.unwrap();
				host.close(PendingWork::Cancel).await.unwrap();
				drop((client, accepted, owner, attachment));
				environment::close(&mut store).await;
				drop(store);
				let mut store = database.open(false, &schemas, limits).await;
				let host = Host::from_seed([121; 32]).unwrap();
				let viewer = Host::from_seed([122; 32]).unwrap();
				let owner = managed::Session::new(
					host.clone(),
					Platform::default(),
					std::num::NonZeroUsize::new(65536).unwrap(),
				);
				let mut attachment = store.attach(&host, vec![owner.registration()]).unwrap();
				let (root, root_control) =
					environment::restore(&attachment, loam::Resource::decode(resource.encode())).await;
				owner.bind(root, root_control.clone()).unwrap();
				let (client, accepted) = connect(&host, &viewer, &root_control).await;
				// Cold-fetch each exact control before issuer receipt recovery.
				// Publication discovery cannot substitute the issuer's wider powers.
				let cold_control = Control::new(client.clone(), client.session().fetch(&control_name).await.unwrap());
				client
					.session()
					.send(
						cold_control.reference(),
						"mutate",
						&[
							i64::from(pause_sequence).into(),
							"pause".into(),
							Argument::Bytes(pause_revision.to_be_bytes().to_vec()),
						],
					)
					.await
					.unwrap();
				assert_eq!(
					revision(&cold_control).await,
					resumed_revision,
					"cold receipt replay does not repeat the lifecycle effect"
				);
				assert_eq!(cold_control.inspect().await.unwrap().view().label, "renamed");
				let cold_inspector =
					Control::new(client.clone(), client.session().fetch(&inspector_name).await.unwrap());
				let effective = cold_inspector.inspect_fixed_access().await.unwrap();
				let UseDescription::Active(active) = effective.view() else {
					panic!("cold inspected use")
				};
				assert_eq!(
					active.effective.permissions().collect::<Vec<_>>(),
					vec![rooms_application::content::permissions::Permission::ObserveWorkspace.key()]
				);
				let description = cold_inspector.describe().await.unwrap();
				let ControlDescription::Available(view) = description.view() else {
					panic!("cold inspector retains its exact powers")
				};
				assert!(view.inspect && !view.pause && !view.delegate_control);
				assert!(cold_inspector.pause(view.revision).await.is_err());
				let management = bootstrap(&client).await;
				let issued = management.issue(&request).await.unwrap();
				assert_eq!(
					client
						.session()
						.send(&issued.access, "durable-name", &[])
						.await
						.unwrap(),
					name
				);
				let child_management = Control::new(client.clone(), issued.control);
				assert_eq!(child_management.inspect().await.unwrap().view().label, "renamed");
				let inventory = child_management.inventory(None, 32).await.unwrap();
				assert_eq!(inventory.view().rows().len(), 3);
				let first = child_management.issue(&first_request).await.unwrap();
				assert!(client.session().send(&first.access, "snapshot", &[]).await.is_ok());
				let revoke = child_management
					.prepare_revoke(revision(&child_management).await)
					.await
					.unwrap();
				revoke.submit().await.unwrap();
				revoke.submit().await.unwrap();
				assert!(client.session().send(&first.access, "snapshot", &[]).await.is_err());
				assert!(matches!(
					child_management.describe().await.unwrap().view(),
					ControlDescription::Unavailable
				));
				assert!(child_management.inventory(None, 32).await.is_err());
				assert!(child_management.inspect().await.is_err());
				assert!(cold_control.durable_name().await.is_err());
				assert!(matches!(
					cold_inspector.describe().await.unwrap().view(),
					ControlDescription::Unavailable
				));
				assert!(
					management.issue(&request).await.is_err(),
					"revoked issuance cannot replay authority"
				);
				owner.close().await.unwrap();
				attachment.close().await.unwrap();
				viewer.close(PendingWork::Cancel).await.unwrap();
				host.close(PendingWork::Cancel).await.unwrap();
				drop((client, accepted, owner, attachment));
				environment::close(&mut store).await;
				database.remove();
			})
			.await
			.expect("management journey deadline");
		})
		.await;
}
