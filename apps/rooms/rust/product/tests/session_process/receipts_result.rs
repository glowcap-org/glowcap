//! A post with files whose outcome cannot be read after it committed reports
//! `Unkept` with its receipt held, as a line that cannot be kept does, and a
//! later look keeps it, against a real session process. The view's fault
//! point is read once per process, so the test runs itself again in a process
//! that arms it.
use super::receipts::{ROOM, posted};
use super::session_rig::{Fixture, attach, host, run_within};
use super::*;
use glowcap::PendingWork;
use rooms_services::session::attached::{Error, Files, GiveBack, Outgoing, Recovered};

const FAULT: &str = "GLOWCAP_ROOMS_VIEW_FAULT";
const TEST: &str = "receipts_result::a_committed_post_whose_outcome_cannot_be_read_is_unkept_and_held";

#[test]
fn a_committed_post_whose_outcome_cannot_be_read_is_unkept_and_held() {
	if std::env::var_os(FAULT).is_none() {
		let output = std::process::Command::new(std::env::current_exe().unwrap())
			.args(["--exact", TEST, "--test-threads=1"])
			.env(FAULT, "result-lost")
			.output()
			.unwrap();
		let (out, err) = (
			String::from_utf8_lossy(&output.stdout),
			String::from_utf8_lossy(&output.stderr),
		);
		assert!(output.status.success() && out.contains("1 passed"), "{out}\n{err}");
		return;
	}
	let fixture = Fixture::start("receipts-result", &["receipts-one", "receipts-two"], ROOM);
	let (one, two) = (&fixture.peers[0], &fixture.peers[1]);
	let room = fixture.room_id(0);
	let text = "posted with files, outcome lost";
	let source = fixture.temp.join("outcome.txt");
	std::fs::write(&source, b"outcome bytes").unwrap();
	run_within(Duration::from_secs(60), async {
		let runtime = host().await;
		let view = attach(&runtime, &one.link).await;
		let sent = view
			.send_files("result-lost", &room, text, &[Outgoing::open(&source).unwrap()], 30_000)
			.await;
		assert!(
			matches!(
				&sent,
				Err(Error::Unkept {
					receipt: GiveBack::Held,
					..
				})
			),
			"a read that failed after the commit is an unkept post: {sent:?}"
		);
		assert!(
			view.held().await.unwrap().contains(&"result-lost".to_owned()),
			"the session still lists the receipt of the post nothing kept"
		);
		// The look reads the same outcome and meets the same loss, so it ends
		// as the post did, with the receipt held, never as a bare error.
		let unread = view.settle_effect("result-lost").await;
		assert!(
			matches!(
				&unread,
				Err(Error::Unkept {
					receipt: GiveBack::Held,
					files: None,
					..
				})
			),
			"a look that cannot read the files is an unkept post: {unread:?}"
		);
		assert!(view.held().await.unwrap().contains(&"result-lost".to_owned()));
		let settled = view.settle_effect("result-lost").await;
		assert_eq!(
			settled.as_ref().ok(),
			Some(&Recovered::Committed {
				files: Some(Files::Complete)
			}),
			"the look reads the post's files from its committed result: {settled:?}"
		);
		assert!(
			!view.held().await.unwrap().contains(&"result-lost".to_owned()),
			"keeping the line frees its place"
		);
		view.say("result-marker", &room, "after the lost outcome")
			.await
			.unwrap();
		drop(view);
		runtime.close(PendingWork::Cancel).await.unwrap();
	});
	assert_eq!(
		posted(&two.state, text, "after the lost outcome"),
		1,
		"the post stood once"
	);
	fixture.finish();
}
