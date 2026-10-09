//! Durable source observation shares the managed owner on LMDB and IndexedDB.
use super::*;
use glowcap::loam::{AccessStatus, ControlDescription, ObservedDescription, UseDescription};
use rooms_application::{content::permissions::Permission, fields::Text};
use rooms_glowcap::client::{
	Client,
	access::{Control, Issuance, Observation, ObservationRequest},
};

async fn request(client: &Client<Platform>, source: &Ref) -> ObservationRequest {
	let sequence = client.session().send(source, "mutation-sequence", &[]).await.unwrap();
	ObservationRequest::new(u32::try_from(sequence.as_i64().unwrap()).unwrap()).unwrap()
}
async fn names(client: &Client<Platform>, observation: &Observation<Platform>) -> [Argument; 2] {
	[
		client
			.session()
			.send(observation.receiver(), "durable-name", &[])
			.await
			.unwrap(),
		client
			.session()
			.send(observation.canceller(), "durable-name", &[])
			.await
			.unwrap(),
	]
}
fn active(state: &rooms_glowcap::client::access::ObservationState) -> glowcap::loam::UseSnapshot<'_> {
	let ObservedDescription::Use(UseDescription::Active(view)) = state.view().source else {
		panic!("active use description")
	};
	view
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn typed_observation_replays_cold_custody_wakes_on_commit_and_hides_inactive_content() {
	run().await;
}
pub(super) async fn run() {
	tokio::task::LocalSet::new().run_until(async {
		environment::within(10_000, async {
			let database = Database::new("observation");
			let schemas = managed::schemas();
			let mut limits = crate::session_storage::limits_for(24, 8, loam::ValueBounds {
				values: 512, capabilities: 8, bytes: 65536, ..Default::default()
			});
			limits.pending_bytes = limits.call_bytes * limits.max_operations;
			limits.ingress_bytes = limits.pending_bytes;
			limits.max_leases *= limits.max_operations;
			limits.cache_slots = 3 * (limits.record_capacity + 2) + 5;
			limits.resident_bytes = limits.cache_slots * limits.record_bytes;
			let mut store = database.open(true, &schemas, limits).await;
			let policy = rooms_glowcap::policy::descriptor().unwrap();
			let observe = policy.value_for_kind(session::KIND, &[Permission::ObserveWorkspace.key()], &[]).unwrap();
			let empty = policy.value_for_kind(session::KIND, &[], &[]).unwrap();
			let resource = environment::create(&store, &policy, schemas[0], &managed::initial_payload(rooms_application::content::session::workspace::Connection::Relay).unwrap(), 4).await;
			let host = Host::from_seed([126; 32]).unwrap();
			let viewer = Host::from_seed([127; 32]).unwrap();
			let owner = managed::Session::new(host.clone(), Platform::default(), std::num::NonZeroUsize::new(65536).unwrap());
			let mut attachment = store.attach(&host, vec![owner.registration()]).unwrap();
			let (root, root_control) = environment::restore(&attachment, resource).await;
			owner.bind(root, root_control.clone()).unwrap();
			owner.initialize().await.unwrap();
			let (client, accepted) = management::connect(&host, &viewer, &root_control).await;
			let management = management::bootstrap(&client).await;
			let issuance = Issuance::new(observe.with_ceiling(observe), management.derivation_sequence().await.unwrap(), management::revision(&management).await, 1, ControlPowers {
				policy_ceiling: Some(observe), pause: true, resume: true, revoke: true, ..Default::default()
			}, "workspace", false);
			let issued = management.issue(&issuance).await.unwrap();
			let registration = request(&client, &issued.access).await;
			let observation = Observation::register(client.clone(), &issued.access, &registration).await.unwrap();
			let replay = Observation::register(client.clone(), &issued.access, &registration).await.unwrap();
			assert_eq!(observation.receiver(), replay.receiver());
			assert_eq!(observation.canceller(), replay.canceller());
			let original_names = names(&client, &observation).await;
			let first = observation.poll(None).await.unwrap();
			assert_eq!(active(&first).effective.permissions().collect::<Vec<_>>(), vec![Permission::ObserveWorkspace.key()]);
			let cursor = *first.view().cursor;
			assert!(!observation.poll(Some(&cursor)).await.unwrap().view().changed);
			let mut intent = Intent::empty();
			intent.standing = Text::new("changed while observing".into()).unwrap();
			let changed = {
				// A parked subscription must not consult ordinary request timing.
				// Suspend that scheduler throughout the wait, then commit content.
				client.platform().observation_suspended.set(true);
				let receiving = observation.receive(&cursor);
				tokio::pin!(receiving);
				for _ in 0..3 {
					tokio::select! {
						_ = &mut receiving => panic!("unchanged receive must stay parked"),
						_ = environment::yield_turn() => {},
					}
				}
				owner.replace_workspace(&intent).await.unwrap();
				let changed = receiving.await.unwrap();
				client.platform().observation_suspended.set(false);
				changed
			};
			assert!(changed.view().changed && changed.view().notices.target);
			let cursor = *changed.view().cursor;
			// Close only local observation custody. Durable registration and its
			// receipt survive independently of the client and physical attachment.
			drop((observation, replay));
			owner.close().await.unwrap();
			attachment.close().await.unwrap();
			viewer.close(PendingWork::Cancel).await.unwrap();
			host.close(PendingWork::Cancel).await.unwrap();
			drop((client, accepted, owner, attachment));
			environment::close(&mut store).await;
			drop(store);

			let mut store = database.open(false, &schemas, limits).await;
			let host = Host::from_seed([126; 32]).unwrap();
			let viewer = Host::from_seed([127; 32]).unwrap();
			let owner = managed::Session::new(host.clone(), Platform::default(), std::num::NonZeroUsize::new(65536).unwrap());
			let mut attachment = store.attach(&host, vec![owner.registration()]).unwrap();
			let (root, root_control) = environment::restore(&attachment, loam::Resource::decode(resource.encode())).await;
			owner.bind(root, root_control.clone()).unwrap();
			let (client, accepted) = management::connect(&host, &viewer, &root_control).await;
			let management = management::bootstrap(&client).await;
			let issued = management.issue(&issuance).await.unwrap();
			let restored = Observation::register(client.clone(), &issued.access, &registration).await.unwrap();
			assert_eq!(names(&client, &restored).await, original_names, "exact durable receiver and cancellation restore through the original receipt");
			let observation = Observation::new(client.clone(), restored.receiver().clone(), restored.canceller().clone());
			assert!(!observation.poll(Some(&cursor)).await.unwrap().view().changed);
			let control = Control::new(client.clone(), issued.control.clone());
			let control_request = request(&client, &issued.control).await;
			let control_observation = Observation::register(client.clone(), &issued.control, &control_request).await.unwrap();
			let control_state = control_observation.poll(None).await.unwrap();
			let control_cursor = *control_state.view().cursor;
			control.pause(management::revision(&control).await).await.unwrap();
			let paused = observation.poll(Some(&cursor)).await.unwrap();
			assert!(paused.view().changed && paused.view().notices.access);
			assert!(matches!(paused.view().source, ObservedDescription::Use(UseDescription::Paused)));
			let paused_cursor = *paused.view().cursor;
			let control_state = control_observation.poll(Some(&control_cursor)).await.unwrap();
			assert!(matches!(control_state.view().source, ObservedDescription::Control(ControlDescription::Available(view)) if view.status == AccessStatus::Paused && view.resume));
			assert!(client.session().send(&issued.access, "snapshot", &[]).await.is_err());
			intent.standing = Text::new("hidden while paused".into()).unwrap();
			owner.replace_workspace(&intent).await.unwrap();
			assert!(!observation.poll(Some(&paused_cursor)).await.unwrap().view().changed, "paused observers learn no protected content activity");
			control.set_policy(control.mutation_sequence().await.unwrap(), management::revision(&control).await, empty).await.unwrap();
			assert!(!observation.poll(Some(&paused_cursor)).await.unwrap().view().changed, "paused observers learn no hidden policy activity");
			control.resume(management::revision(&control).await).await.unwrap();
			let narrowed = observation.poll(Some(&paused_cursor)).await.unwrap();
			assert_eq!(active(&narrowed).effective.permissions().len(), 0);
			assert!(client.session().send(&issued.access, "snapshot", &[]).await.is_err(), "observation metadata grants no content authority");
			let narrowed_cursor = *narrowed.view().cursor;
			control.revoke(management::revision(&control).await).await.unwrap();
			let revoked = observation.poll(Some(&narrowed_cursor)).await.unwrap();
			assert!(matches!(revoked.view().source, ObservedDescription::Use(UseDescription::Revoked)));
			let terminal = *revoked.view().cursor;
			let receiving = observation.receive(&terminal);
			tokio::pin!(receiving);
			tokio::select! {
				_ = &mut receiving => panic!("terminal receive waits for independent cancellation"),
				_ = environment::yield_turn() => {},
			}
			assert!(observation.cancel().await.unwrap());
			assert!(receiving.await.is_err());
			assert!(!observation.cancel().await.unwrap(), "exact cancellation retry is idempotent");
			assert!(observation.poll(None).await.is_err());
			assert!(control_observation.cancel().await.unwrap(), "management registration has independent cancellation");
			assert!(!control_observation.cancel().await.unwrap());
			owner.close().await.unwrap();
			attachment.close().await.unwrap();
			viewer.close(PendingWork::Cancel).await.unwrap();
			host.close(PendingWork::Cancel).await.unwrap();
			drop((client, accepted, owner, attachment));
			environment::close(&mut store).await;
			database.remove();
		}).await.expect("source observation journey deadline");
	}).await;
}
