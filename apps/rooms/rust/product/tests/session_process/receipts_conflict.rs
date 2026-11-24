//! A line whose keeping met a moving workspace on every attempt leaves its
//! receipt listed by the session's held effects, and a later look keeps the
//! line, against a real session process. The view's fault point is read once
//! per process, so the test runs itself again in a process that arms it.
use super::receipts::{ROOM, posted};
use super::session_rig::{Fixture, attach, host, run_within};
use super::*;
use glowcap::PendingWork;
use rooms_services::session::attached::{Error, GiveBack, Recovered};

const FAULT: &str = "GLOWCAP_ROOMS_VIEW_FAULT";
const TEST: &str = "receipts_conflict::a_conflicting_keep_holds_its_receipt_until_a_later_look_keeps_the_line";

#[test]
fn a_conflicting_keep_holds_its_receipt_until_a_later_look_keeps_the_line() {
	if std::env::var_os(FAULT).is_none() {
		let output = std::process::Command::new(std::env::current_exe().unwrap())
			.args(["--exact", TEST, "--test-threads=1"])
			.env(FAULT, "keep-conflict")
			.output()
			.unwrap();
		let (out, err) = (
			String::from_utf8_lossy(&output.stdout),
			String::from_utf8_lossy(&output.stderr),
		);
		assert!(output.status.success() && out.contains("1 passed"), "{out}\n{err}");
		return;
	}
	let fixture = Fixture::start("receipts-conflict", &["receipts-one", "receipts-two"], ROOM);
	let (one, two) = (&fixture.peers[0], &fixture.peers[1]);
	let room = fixture.room_id(0);
	let text = "posted while the workspace moved";
	run_within(Duration::from_secs(60), async {
		let runtime = host().await;
		let view = attach(&runtime, &one.link).await;
		let sent = view.say("conflicting-keep", &room, text).await;
		assert!(
			matches!(
				&sent,
				Err(Error::Unkept {
					receipt: GiveBack::Held,
					..
				})
			),
			"every attempt to keep the line met a moved workspace: {sent:?}"
		);
		assert!(
			view.held().await.unwrap().contains(&"conflicting-keep".to_owned()),
			"the session still lists the receipt of a line nothing kept"
		);
		let settled = view.settle_effect("conflicting-keep").await;
		assert_eq!(
			settled.as_ref().ok(),
			Some(&Recovered::Committed { files: None }),
			"a line with no files says none: {settled:?}"
		);
		assert!(
			!view.held().await.unwrap().contains(&"conflicting-keep".to_owned()),
			"keeping the line frees its place"
		);
		view.say("conflicting-marker", &room, "after the conflict")
			.await
			.unwrap();
		drop(view);
		runtime.close(PendingWork::Cancel).await.unwrap();
	});
	assert_eq!(
		posted(&two.state, text, "after the conflict"),
		1,
		"the line posted once"
	);
	fixture.finish();
}
