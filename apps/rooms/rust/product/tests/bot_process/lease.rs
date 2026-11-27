//! The bot directory's lease: a `status` probe never keeps a `serve` out of
//! it and never reads another probe as a running `serve`.
use super::rig::{Rig, eventually};
use serde_json::json;

#[test]
fn a_serve_starting_while_a_status_probe_holds_the_lease_is_not_refused() {
	let rig = Rig::new("bot-probe-then-serve");
	assert!(rig.serve(json!({}), None).stop().success());
	// The probe holds until the serve says it met the hold, so the proof
	// cannot pass by a serve that started after the probe ended.
	let mut probe = rig.probe_holding();
	let bot = rig.serve(json!({}), None);
	assert!(probe.wait().success(), "the probe failed");
	assert!(
		rig.dir.join("lease-met").exists(),
		"the serve never met the probe's hold"
	);
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert!(!rig.output().contains("in-use"), "{}", rig.output());
}

#[test]
fn a_status_probe_never_reports_another_probe_as_a_running_serve() {
	let rig = Rig::new("bot-probe-then-probe");
	assert!(rig.serve(json!({}), None).stop().success());
	let mut probe = rig.probe_holding();
	let report = rig.status();
	assert_eq!(report["running"], false, "{report}");
	rig.release_probe();
	assert!(probe.wait().success(), "the probe failed");
}

/// A start that cannot write its status ends with that error before it
/// serves, so every serving bot has observable status.
#[test]
fn a_start_that_cannot_write_its_status_ends_instead_of_serving_under_the_old_one() {
	let rig = Rig::new("bot-status-unwritable");
	assert!(rig.serve(json!({}), None).stop().success());
	// A directory where the file goes makes the replace fail, as a failing
	// disk would.
	let status = rig.dir.join("status.json");
	std::fs::remove_file(&status).unwrap();
	std::fs::create_dir(&status).unwrap();
	let mut start = rig.serve_stored_refused();
	assert!(
		!start.wait().success(),
		"a start that could not write its status served"
	);
	assert_eq!(
		rig.output().matches("ROOMS-BOT-SERVING").count(),
		1,
		"the second start announced serving: {}",
		rig.output()
	);
	assert!(rig.output().contains("\"ok\":false"), "{}", rig.output());
}

/// A restart holds the directory before it can publish a status. The prior
/// bot may have been killed while its last published status was ready.
#[test]
fn a_restart_cannot_claim_the_killed_publishers_status() {
	let rig = Rig::new("bot-publisher");
	let mut old = rig.serve(json!({"model": ["old-model"]}), None);
	eventually("the bot to report ready", || {
		rig.run("ready", json!({})).1.then_some(())
	});
	old.kill();
	old.process.wait();
	let stopped = rig.status();
	assert_eq!(stopped["running"], false);
	assert_eq!(stopped["status"]["model"], "old-model");

	// Hold just the directory lease, the exact state before startup publishes.
	let lease = std::fs::File::open(rig.dir.join("lock")).unwrap();
	lease.lock().unwrap();
	let starting = rig.status();
	assert_eq!(starting["running"], true);
	assert!(starting["status"].is_null());
	assert!(!rig.run("ready", json!({})).1);
	drop(lease);

	let new = rig.serve(json!({"model": ["new-model"]}), None);
	assert_eq!(rig.status()["status"]["model"], "new-model");
	eventually("the bot to report ready", || {
		rig.run("ready", json!({})).1.then_some(())
	});
	assert!(new.stop().success());
}
