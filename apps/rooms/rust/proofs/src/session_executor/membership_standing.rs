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
pub(super) async fn profile(
	host: &Host,
	owner: &managed::Session<Platform>,
	workspace: &Workspace<Platform>,
	seat: &Ref,
	callback: &Ref,
	live: &managed::Membership<Platform>,
) {
	async fn wait(live: &managed::Membership<Platform>, host: &Host, seat: &Ref, kind: &str, about: &str, count: i64) {
		let expected = Argument::List(vec![kind.into(), about.into(), count.into()]);
		assert!(
			environment::within(2_000, async {
				while host.send(seat, "last-profile", &[]).await.unwrap() != expected {
					environment::yield_turn().await;
				}
			})
			.await
			.is_some(),
			"profile {kind:?}/{about:?} call {count} did not settle: {:?}, seat {:?}",
			live.status(),
			host.send(seat, "last-profile", &[]).await
		);
	}
	use rooms_application::content::permissions::Permission::{InteractWorkspace, ObserveWorkspace, ReplaceWorkspace};
	let policy = rooms_glowcap::policy::descriptor().unwrap();
	let facet = |permission: rooms_application::content::permissions::Permission| {
		policy
			.value_for_kind(session::KIND, &[ObserveWorkspace.key(), permission.key()], &[])
			.unwrap()
	};
	let (limited, _) = owner
		.derive(facet(InteractWorkspace), 1, ControlPowers::default())
		.await
		.unwrap();
	let posting = Workspace::local(host.clone(), Platform::default(), limited);
	let base = workspace.snapshot().await.unwrap().revision;
	let blocked = posting
		.prepare_command(
			"posting-only-profile",
			base,
			"setRoomProfile",
			&["conversation".into(), "bot".into(), "Unauthorized".into()],
		)
		.await
		.unwrap();
	assert!(
		blocked.submit().await.is_err(),
		"posting-only access cannot declare who is speaking"
	);
	let (limited, _) = owner
		.derive(facet(ReplaceWorkspace), 1, ControlPowers::default())
		.await
		.unwrap();
	let editor = Workspace::local(host.clone(), Platform::default(), limited);
	command(&editor, 13, "setRoomProfile", &["conversation", "bot", "Tests links"]).await;
	let snapshot = workspace.snapshot().await.unwrap();
	assert_eq!(
		snapshot.intent.room("conversation").unwrap().profile.about(),
		"Tests links"
	);
	wait(live, host, seat, "", "", 0).await;
	host.send(
		callback,
		"notify",
		&["room".into(), "".into(), "carries".into(), "profiles".into()],
	)
	.await
	.unwrap();
	wait(live, host, seat, "bot", "Tests links", 1).await;
	let current = workspace.snapshot().await.unwrap();
	let row = current.intent.room("conversation").unwrap();
	let replay = editor
		.prepare_command(
			"another-writer-profile",
			current.revision,
			"applyRoomProfile",
			&[
				"conversation".into(),
				serde_json::to_string(&row.seat.unwrap()).unwrap(),
				"bot".into(),
				"Tests links".into(),
			],
		)
		.await
		.unwrap();
	assert!(
		replay.submit().await.is_err(),
		"only the original membership source can synchronize"
	);
	command(&editor, 14, "setRoomProfile", &["conversation", "", ""]).await;
	wait(live, host, seat, "", "", 2).await;
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
	// journey permits earlier receipt and content wakes to finish in any order.
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
