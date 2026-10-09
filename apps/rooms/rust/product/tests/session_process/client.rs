//! The executable publishes independent managed use and control. A restart
//! replays the original application receipt without recreating authority.
use glowcap::loam::{ControlDescription, ControlPowers};
use glowcap::{CaptpVersion, ConnectOptions, PendingWork, Runtime, RuntimeConfig, iroh, tcp};
use rooms_application::content::{permissions::Permission, session};
use rooms_glowcap::client::{
	Client,
	access::{Control, Issuance, ObservationRequest},
	workspace::{EffectStatus, Workspace},
};
use rooms_platform::HostPlatform;
use std::time::Duration;

pub fn exercise(link: &str, management_link: &str, original_base: Option<u64>) -> u64 {
	tokio::runtime::Builder::new_current_thread()
		.enable_all()
		.build()
		.unwrap()
		.block_on(tokio::task::LocalSet::new().run_until(async {
			tokio::time::timeout(Duration::from_secs(8), attached(link, management_link, original_base))
				.await
				.expect("managed executable client deadline")
		}))
}
async fn revision(control: &Control<HostPlatform>) -> u64 {
	let state = control.describe().await.unwrap();
	let ControlDescription::Available(view) = state.view() else {
		panic!("held management unavailable")
	};
	view.revision
}
async fn attached(link: &str, management_link: &str, original_base: Option<u64>) -> u64 {
	let parsed = glowcap::parse_sturdyref(link, CaptpVersion::V1_0).unwrap();
	let management = glowcap::parse_sturdyref(management_link, CaptpVersion::V1_0).unwrap();
	assert_eq!(parsed.locator, management.locator);
	assert_ne!(
		parsed.swissnum, management.swissnum,
		"management has its own publication"
	);
	let runtime = Runtime::open(RuntimeConfig::providers([
		tcp::provider(Default::default()),
		iroh::provider(iroh::Config::new(iroh::Reachability::Direct)),
	]))
	.await
	.unwrap();
	let connection = runtime
		.connect(&parsed.locator, ConnectOptions::default())
		.await
		.unwrap();
	let reference = connection
		.fetch(std::str::from_utf8(&parsed.swissnum).unwrap())
		.await
		.unwrap();
	let held_control = connection
		.fetch(std::str::from_utf8(&management.swissnum).unwrap())
		.await
		.unwrap();
	let client = Client::new(connection, HostPlatform);
	let workspace = Workspace::new(client.clone(), reference);
	let control = Control::new(client.clone(), held_control);
	let initial = workspace.snapshot().await.unwrap();
	let base = original_base.unwrap_or(initial.revision);
	let command = workspace
		.prepare_command("executable-attach", base, "setStanding", &["present".into()])
		.await
		.unwrap();
	assert_eq!(command.submit().await.unwrap(), EffectStatus::Committed);
	let after = workspace.snapshot().await.unwrap();
	assert_eq!(after.intent.standing.text().as_str(), Some("present"));
	if original_base.is_some() {
		assert_eq!(after.revision, initial.revision, "cold receipt replay changed intent");
	}
	assert_eq!(command.submit().await.unwrap(), EffectStatus::Committed);
	assert_eq!(workspace.snapshot().await.unwrap().revision, after.revision);
	let observer = rooms_glowcap::policy::descriptor()
		.unwrap()
		.value_for_kind(session::KIND, &[Permission::ObserveWorkspace.key()], &[])
		.unwrap();
	let issuance = Issuance::new(
		observer.with_ceiling(observer),
		control.derivation_sequence().await.unwrap(),
		revision(&control).await,
		0,
		ControlPowers {
			revoke: true,
			..Default::default()
		},
		"Executable observer",
		false,
	);
	let issued = control.issue(&issuance).await.unwrap();
	let view = Workspace::new(client.clone(), issued.access);
	let child = Control::new(client, issued.control);
	assert_eq!(view.snapshot().await.unwrap().intent, after.intent);
	let write = view
		.prepare_command(
			"observer-write",
			after.revision,
			"setStanding",
			&["must not appear".into()],
		)
		.await
		.unwrap();
	assert!(write.submit().await.is_err(), "ObserveWorkspace admitted a write");
	let request = ObservationRequest::new(view.mutation_sequence().await.unwrap()).unwrap();
	let observation = view.observe(&request).await.unwrap();
	observation.poll(None).await.unwrap();
	child.revoke(revision(&child).await).await.unwrap();
	assert!(view.snapshot().await.is_err(), "revoked use remained readable");
	observation.cancel().await.unwrap();
	drop((
		observation,
		request,
		write,
		view,
		child,
		issuance,
		control,
		workspace,
		command,
	));
	runtime.close(PendingWork::Cancel).await.unwrap();
	base
}

/// A live remote receive must retire before its source attachment closes.
/// Keep the client connected while the executable receives its stop signal.
pub fn shutdown_with_live_observer(link: &str, halt: impl FnOnce()) {
	tokio::runtime::Builder::new_current_thread()
		.enable_all()
		.build()
		.unwrap()
		.block_on(tokio::task::LocalSet::new().run_until(async {
			let parsed = glowcap::parse_sturdyref(link, CaptpVersion::V1_0).unwrap();
			let runtime = Runtime::open(RuntimeConfig::providers([
				tcp::provider(Default::default()),
				iroh::provider(iroh::Config::new(iroh::Reachability::Direct)),
			]))
			.await
			.unwrap();
			let connection = runtime
				.connect(&parsed.locator, ConnectOptions::default())
				.await
				.unwrap();
			let reference = connection
				.fetch(std::str::from_utf8(&parsed.swissnum).unwrap())
				.await
				.unwrap();
			let workspace = Workspace::new(Client::new(connection, HostPlatform), reference);
			let observation = workspace.observe(&ObservationRequest::new(2).unwrap()).await.unwrap();
			let cursor = *observation.poll(None).await.unwrap().view().cursor;
			let receiving = tokio::task::spawn_local(async move { observation.receive(&cursor).await });
			tokio::task::yield_now().await;
			// The same connection's subsequent reply fences admission of its receive.
			workspace.snapshot().await.unwrap();
			assert!(!receiving.is_finished(), "the observation was not waiting at shutdown");
			halt();
			tokio::time::timeout(Duration::from_secs(5), receiving)
				.await
				.expect("remote observation did not retire after source shutdown")
				.unwrap()
				.err()
				.expect("the stopped source still answered a live observation");
			runtime.close(PendingWork::Cancel).await.unwrap();
		}));
}
