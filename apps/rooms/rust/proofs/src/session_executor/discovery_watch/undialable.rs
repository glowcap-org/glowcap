//! A saved address on a transport this session does not dial is one standing
//! coded refusal, at the discovery watch and at the membership alike, dialed
//! again only by an explicit retry.
use super::*;
use rooms_application::failure::FailureCode;
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
	assert_undialable(&refused);
	let discovery = managed::MembershipKinds {
		discovery: true,
		directories: false,
		rooms: false,
		directs: false,
	};
	standing(owner, workspace, discovery, 1, Some(dials)).await;
	// A membership registers a nickname and realizes through a source that may
	// interact with the workspace. Its start restores the saved address inside
	// its own verbs, which the restoration counter does not watch.
	let mut registering = stale.clone();
	registering.nick = Text::new("stale".into()).unwrap();
	registering.source = Some(key(4));
	let mut only_stale = Intent::empty();
	only_stale.directories = List::new(vec![registering]).unwrap();
	owner.replace_workspace(&only_stale).await.unwrap();
	let membership = managed::MembershipKinds {
		discovery: false,
		directories: true,
		rooms: false,
		directs: false,
	};
	standing(owner, workspace, membership, 0, None).await;
}

/// Supervise the workspace with one kind of worker. The refusal is told once,
/// no recovery wake reconciles while only it stands, and an explicit retry
/// reconciles again. `dials` counts the saved address's restorations where
/// the counter watches the verb that restores it.
async fn standing(
	owner: &managed::Session<Platform>,
	workspace: &Workspace<Platform>,
	kinds: managed::MembershipKinds,
	ready_beside: usize,
	dials: Option<&Cell<usize>>,
) {
	let dialed = dials.map(Cell::get);
	let (reports, mut reported) = watch::channel((0usize, 0usize, Vec::<rooms_runtime::Error>::new()));
	let mut activity = owner
		.supervise_workspace(
			workspace.reference(),
			"ocapn://discovery.id",
			realization::Entropy::seeded(360),
			kinds,
			|_| Box::new(|_| Ok(Argument::Void)),
			move |report| {
				let report = report.expect("workspace observation admission");
				let failures = report.failures.iter().map(|(_, error)| error.clone()).collect();
				reports.send_modify(|(told, ready, standing)| {
					*told += 1;
					*ready = report.ready;
					*standing = failures;
				});
			},
		)
		.unwrap();
	assert!(activity.ready().await.is_err(), "a standing refusal fails readiness");
	let (told, ready, failures) = loop {
		let seen = reported.borrow_and_update().clone();
		if !seen.2.is_empty() {
			break seen;
		}
		reported.changed().await.unwrap();
	};
	assert_eq!(
		ready, ready_beside,
		"the reachable directory stays ready beside the refusal"
	);
	assert_eq!(failures.len(), 1, "{failures:?}");
	assert_undialable(&failures[0]);
	let attempt = dials.map(Cell::get);
	assert!(dials.is_none() || attempt > dialed, "the saved address was not dialed");
	// A refusal that clears only with a change holds no recovery timer, so no
	// wake tells it again or dials the address again.
	assert!(environment::within(900, std::future::pending::<()>()).await.is_none());
	assert_eq!(
		reported.borrow().0,
		told,
		"a recovery wake told a standing refusal again"
	);
	assert_eq!(
		dials.map(Cell::get),
		attempt,
		"a recovery wake dialed a standing refusal again"
	);
	activity.retry();
	environment::within(2_000, async {
		while reported.borrow().0 == told {
			environment::yield_turn().await;
		}
	})
	.await
	.expect("an explicit retry reconciles the saved address again");
	assert!(
		dials.is_none() || dials.map(Cell::get) > attempt,
		"an explicit retry did not dial the saved address"
	);
	activity.close().await.unwrap();
}

fn assert_undialable(error: &rooms_runtime::Error) {
	let rooms_runtime::Error::Captp(binding) = error else {
		panic!("restoration must retain its binding failure: {error:?}");
	};
	assert_eq!(
		binding.cause(),
		glowcap::BreakCause::local(glowcap::BreakReason::TransportUnavailable)
			.with_fetch()
			.with_restoration()
	);
	assert_eq!(
		rooms_glowcap::client::binding_failure(binding).unwrap().code,
		FailureCode::SavedTransportUnavailable
	);
}
