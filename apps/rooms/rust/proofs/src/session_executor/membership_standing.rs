//! Standing inheritance is reconciled by the actual membership worker, including
//! explicit empty overrides, source suspension and unrelated content changes.
use super::*;
use rooms_glowcap::client::workspace::Workspace;

async fn command(workspace: &Workspace<Platform>, number: usize, name: &str, args: &[&str]) {
	for attempt in 0..4 {
		let snapshot = workspace.snapshot().await.unwrap();
		let command = workspace
			.prepare_command(
				&format!("standing-proof-{number}"),
				snapshot.revision,
				name,
				&args.iter().map(|value| (*value).into()).collect::<Vec<_>>(),
			)
			.await
			.unwrap();
		let status = command.submit().await.unwrap();
		if status == rooms_glowcap::client::workspace::EffectStatus::Conflict {
			assert!(attempt < 3, "standing gesture repeatedly conflicted before admission");
			continue;
		}
		assert_eq!(status, rooms_glowcap::client::workspace::EffectStatus::Committed);
		return;
	}
}
async fn applied(host: &Host, seat: &Ref, reason: &str) {
	assert!(
		environment::within(2_000, async {
			loop {
				if host.send(seat, "last-standing", &[]).await.unwrap().as_str() == Some(reason) {
					break;
				}
				environment::yield_turn().await;
			}
		})
		.await
		.is_some(),
		"membership did not apply {reason:?}"
	);
}
pub(super) async fn run(
	host: &Host,
	owner: &managed::Session<Platform>,
	workspace: &Workspace<Platform>,
	seat: &Ref,
	control: &Ref,
) {
	for (number, name, args, expected) in [
		(0, "setStanding", vec!["global away"], "global away"),
		(1, "setRoomStanding", vec!["conversation", "room away"], "room away"),
		(2, "setStanding", vec!["new global"], "room away"),
		(3, "setRoomStanding", vec!["conversation", ""], ""),
		(4, "setRoomStanding", vec!["conversation"], "new global"),
		(
			5,
			"setDirectoryStanding",
			vec!["directory", "directory away"],
			"directory away",
		),
		(6, "setDirectoryStanding", vec!["directory"], "new global"),
	] {
		command(workspace, number, name, &args).await;
		applied(host, seat, expected).await;
	}
	let count = host.send(seat, "standing-count", &[]).await.unwrap();
	// The owner-level standing test measures snapshot reuse directly. This
	// journey permits earlier receipt and content wakes to finish in any order. status-allow: event or source ordering
	command(workspace, 7, "setDraft", &["conversation", "unrelated"]).await;
	assert_eq!(
		host.send(seat, "standing-count", &[]).await.unwrap(),
		count,
		"unrelated changes do not redispatch standing"
	);
	let mut intent = workspace.snapshot().await.unwrap().intent;
	publication_results::lifecycle(host, control, "pause").await;
	intent.standing = rooms_application::fields::Text::new("while source paused".into()).unwrap();
	owner.replace_workspace(&intent).await.unwrap();
	for _ in 0..8 {
		environment::yield_turn().await;
	}
	assert_eq!(host.send(seat, "standing-count", &[]).await.unwrap(), count);
	publication_results::lifecycle(host, control, "resume").await;
	applied(host, seat, "while source paused").await;
	command(workspace, 8, "setStanding", &[""]).await;
	applied(host, seat, "").await;
	command(workspace, 9, "setDraft", &["conversation", ""]).await;
	let before = host.send(seat, "standing-count", &[]).await.unwrap().as_i64().unwrap();
	host.send(seat, "refuse-next-standing", &[]).await.unwrap();
	command(workspace, 10, "setStanding", &["refused preference"]).await;
	assert!(
		environment::within(2_000, async {
			while host.send(seat, "standing-refusals", &[]).await.unwrap().as_i64() != Some(1) {
				environment::yield_turn().await;
			}
		})
		.await
		.is_some(),
		"the upstream must actually refuse before this recovery proof"
	);
	command(workspace, 11, "setStanding", &["latest preference"]).await;
	applied(host, seat, "latest preference").await;
	assert_eq!(
		host.send(seat, "standing-count", &[]).await.unwrap().as_i64(),
		Some(before + 1),
		"a refused preference cannot apply later before the newer intent"
	);
	command(workspace, 12, "setStanding", &[""]).await;
	applied(host, seat, "").await;
}
