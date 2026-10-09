//! Workspace observation creates and retires workers without manual reconciliation.
use super::*;
use rooms_application::content::session::workspace;
use rooms_glowcap::client::workspace::Workspace;
use tokio::sync::watch;

pub(super) async fn run(
	host: &Host,
	owner: &managed::Session<Platform>,
	source: &Ref,
	platform: &Platform,
	joins: &Cell<usize>,
) {
	let workspace = Workspace::local(host.clone(), platform.clone(), source.clone());
	let prior = joins.get();
	let received = Rc::new(Cell::new(0));
	let (reports, mut reported) = watch::channel((0usize, Vec::new()));
	let mut activity = owner
		.supervise_workspace(
			source,
			"ocapn://member.id",
			realization::Entropy::seeded(300),
			managed::MembershipKinds::ROOMS,
			{
				let received = received.clone();
				let source = source.clone();
				move |_| {
					let received = received.clone();
					let source = source.clone();
					Box::new(move |event| {
						let managed::MembershipEvent::Notification { origin: actual, .. } = event else {
							panic!("room notification context");
						};
						assert_eq!(actual.source(), &source, "consumer receives the exact initiating grant");
						received.set(received.get() + 1);
						Ok(Argument::Void)
					})
				}
			},
			move |report| {
				let report = report.expect("workspace activity admission");
				reports.send_replace((report.ready, report.failures.clone()));
			},
		)
		.unwrap();
	assert!(
		owner
			.supervise_workspace(
				source,
				"ocapn://member.id",
				realization::Entropy::seeded(400),
				managed::MembershipKinds::ROOMS,
				|_| Box::new(|_| Ok(Argument::Void)),
				|_| {}
			)
			.is_err(),
		"one session admits one workspace observation owner"
	);
	activity.ready().await.unwrap();
	assert_eq!(joins.get(), prior + 1);
	let mut intent = workspace.snapshot().await.unwrap().intent;
	let workspace::Conversation::Room(second) = &intent.conversations.as_slice()[1] else {
		unreachable!()
	};
	let second_callback = owner
		.restore_custody(&[workspace::InboxSelection::room(second, &intent).unwrap().coordinate()])
		.await
		.unwrap()
		.remove(0);
	host.send(&second_callback, "notify", &[]).await.unwrap();
	assert_eq!(received.get(), 1);
	let workspace::Conversation::Room(first) = &mut intent.conversations.as_mut_slice()[0] else {
		unreachable!()
	};
	first.reconnect = workspace::Reconnect::Requested;
	owner.replace_workspace(&intent).await.unwrap();
	ready_count(&mut reported, 2).await;
	assert_eq!(
		joins.get(),
		prior + 2,
		"new intent wakes the worker without a reconcile call"
	);
	let mut intent = workspace.snapshot().await.unwrap().intent;
	let workspace::Conversation::Room(first) = &intent.conversations.as_slice()[0] else {
		unreachable!()
	};
	let first_callback = owner
		.restore_custody(&[workspace::InboxSelection::room(first, &intent).unwrap().coordinate()])
		.await
		.unwrap()
		.remove(0);
	host.send(&first_callback, "notify", &[]).await.unwrap();
	let workspace::Conversation::Room(first) = &mut intent.conversations.as_mut_slice()[0] else {
		unreachable!()
	};
	first.reconnect = workspace::Reconnect::Manual;
	first.seat = None;
	owner.replace_workspace(&intent).await.unwrap();
	ready_count(&mut reported, 1).await;
	assert!(host.send(&first_callback, "notify", &[]).await.is_err());
	host.send(&second_callback, "notify", &[]).await.unwrap();
	assert_eq!(received.get(), 3);
	platform.refuse_observation.set(true);
	assert!(
		activity.close().await.is_err(),
		"failed cancellation retains the aggregate"
	);
	assert!(activity.is_active());
	platform.refuse_observation.set(false);
	activity.close().await.unwrap();
	assert!(!activity.is_active());
	activity.close().await.unwrap();
	assert!(host.send(&second_callback, "notify", &[]).await.is_err());
	assert_eq!(joins.get(), prior + 2, "cleanup cannot redispatch membership effects");
}
async fn ready_count(
	reported: &mut watch::Receiver<(usize, Vec<(managed::MembershipTarget, glowcap::Error)>)>,
	expected: usize,
) {
	loop {
		let (ready, failures) = reported.borrow_and_update().clone();
		assert!(failures.is_empty(), "workspace realization failed: {failures:?}");
		if ready == expected {
			return;
		}
		reported.changed().await.unwrap();
	}
}
