//! A viewer gap refreshes discovery after exact drain without registering a member.
use super::*;

pub(super) async fn run(
	owner: &managed::Session<Platform>,
	workspace: &Workspace<Platform>,
	exporter: &Host,
	state: &Rc<RefCell<rooms_application::server::directory::Directory<u64, Ref>>>,
	watches: &Cell<usize>,
	refuse_cancel: &Cell<bool>,
) {
	let snapshots = Rc::new(Cell::new(0));
	let failures = Rc::new(Cell::new(0));
	let prior = watches.get();
	let mut activity = owner
		.supervise_workspace(
			workspace.reference(),
			"ocapn://discovery.id",
			realization::Entropy::seeded(350),
			managed::MembershipKinds {
				discovery: true,
				directories: false,
				rooms: false,
				directs: false,
			},
			{
				let snapshots = snapshots.clone();
				move |_| {
					let snapshots = snapshots.clone();
					Box::new(move |event| {
						if matches!(event, managed::MembershipEvent::DirectorySnapshot { .. }) {
							snapshots.set(snapshots.get() + 1);
						}
						Ok(Argument::Void)
					})
				}
			},
			{
				let failures = failures.clone();
				move |report| {
					if report.is_err() || report.is_ok_and(|report| !report.failures.is_empty()) {
						failures.set(failures.get() + 1);
					}
				}
			},
		)
		.unwrap();
	activity.ready().await.unwrap();
	assert_eq!(snapshots.get(), 1);
	let stale = state.borrow().watchers().next().unwrap().1.clone();
	refuse_cancel.set(true);
	workspace.resynchronize_discovery().await.unwrap();
	environment::within(2_000, async {
		while failures.get() == 0 {
			environment::yield_turn().await;
		}
	})
	.await
	.expect("discovery refresh reports the exact cancellation refusal");
	assert_eq!(snapshots.get(), 1, "a refused cancellation cannot admit a new snapshot");
	assert_eq!(
		watches.get(),
		prior + 1,
		"one exact discovery owner remains through refusal"
	);
	assert_eq!(state.borrow().watchers().count(), 1);
	refuse_cancel.set(false);
	activity.retry();
	environment::within(2_000, async {
		while snapshots.get() != 2 {
			environment::yield_turn().await;
		}
	})
	.await
	.expect("retry drains the old discovery before delivering a fresh snapshot");
	assert_eq!(watches.get(), prior + 2);
	assert_ne!(state.borrow().watchers().next().unwrap().1, &stale);
	assert!(
		exporter
			.send(&stale, "notify", &["count".into(), "room".into(), 1.into()])
			.await
			.is_err()
	);
	assert_eq!(
		state.borrow().registered_nick(1),
		None,
		"refresh has no membership admission"
	);
	activity.close().await.unwrap();
	assert_eq!(state.borrow().watchers().count(), 0);
}
