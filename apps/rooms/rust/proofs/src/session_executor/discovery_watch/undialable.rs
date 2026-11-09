//! A saved address on a transport this session does not dial is one standing
//! coded refusal, dialed again only by an explicit retry.
use super::*;
use rooms_application::failure::{Failure, FailureCode};
use tokio::sync::watch;

pub(super) async fn run(
	owner: &managed::Session<Platform>,
	workspace: &Workspace<Platform>,
	intent: &Intent,
	stale: &workspace::Directory,
	dials: &Cell<usize>,
) {
	owner.replace_workspace(intent).await.unwrap();
	let Err(refused) = owner.watch_directory(stale, |_, _| Ok(())).await else {
		panic!("a saved address this session cannot dial was watched");
	};
	let refused = refused.to_string();
	let coded = Failure::parse(&refused)
		.unwrap_or_else(|| panic!("an undialable saved address carries its wire code: {refused}"));
	assert_eq!(coded.code, FailureCode::SavedTransportUnavailable, "{refused}");
	let dialed = dials.get();
	let (reports, mut reported) = watch::channel((0usize, Vec::<String>::new()));
	let mut activity = owner
		.supervise_workspace(
			workspace.reference(),
			"ocapn://discovery.id",
			realization::Entropy::seeded(360),
			managed::MembershipKinds {
				discovery: true,
				directories: false,
				rooms: false,
				directs: false,
			},
			|_| Box::new(|_| Ok(Argument::Void)),
			move |report| {
				let report = report.expect("workspace observation admission");
				let failures = report.failures.iter().map(|(_, error)| error.to_string()).collect();
				reports.send_replace((report.ready, failures));
			},
		)
		.unwrap();
	assert!(activity.ready().await.is_err(), "a standing refusal fails readiness");
	// Recovery wakes keep reporting while a failure stands. Each report tells
	// the same refusal without dialing the saved address again.
	for _ in 0..4 {
		reported.changed().await.unwrap();
	}
	let (ready, failures) = reported.borrow().clone();
	assert_eq!(ready, 1, "the reachable directory stays ready beside the refusal");
	assert_eq!(failures.len(), 1, "{failures:?}");
	assert!(
		Failure::parse(&failures[0]).is_some_and(|coded| coded.code == FailureCode::SavedTransportUnavailable),
		"{failures:?}"
	);
	assert_eq!(
		dials.get(),
		dialed + 1,
		"recovery wakes dialed a standing refusal again"
	);
	activity.retry();
	environment::within(2_000, async {
		while dials.get() < dialed + 2 {
			environment::yield_turn().await;
		}
	})
	.await
	.expect("an explicit retry dials the saved address again");
	activity.close().await.unwrap();
}
