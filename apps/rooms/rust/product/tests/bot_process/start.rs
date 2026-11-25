//! What `serve` refuses before it takes the lease or stores anything: an agent
//! that is not installed and an environment variable it cannot read.
use super::rig::Rig;
use super::words;
use serde_json::json;

#[test]
fn serve_refuses_an_agent_that_is_not_installed_before_storing_anything() {
	let rig = Rig::new("bot-no-agent");
	let empty = rig.dir.with_file_name("empty-path");
	std::fs::create_dir(&empty).unwrap();
	let (refused, ok) = rig.run_env(
		"serve",
		json!({"rooms-dir": [rig.rooms], "harness": ["claude"], "glowcap": [rig.glowcap()]}),
		&[("PATH", empty.to_str().unwrap())],
	);
	assert!(!ok && refused["error"]["class"] == "config", "{refused}");
	// The same shape `session access` prints, retry advice included.
	assert_eq!(refused["error"]["retry"], "after-request-change", "{refused}");
	let message = refused["error"]["message"].as_str().unwrap();
	assert!(message.contains("--harness claude runs claude"), "{message}");
	assert!(
		!rig.dir.join("config.json").exists(),
		"a refused serve stored its settings"
	);
}

#[test]
fn an_unknown_variable_is_refused_by_name_before_anything_starts() {
	let rig = Rig::new("bot-unknown-variable");
	let (said, ok) = rig.run_env("serve", json!({}), &[("GLOWCAP_ROOMS_BOT_UNKNOWN", "value")]);
	assert!(!ok, "{said}");
	let message = said["error"]["message"].as_str().unwrap();
	assert!(message.starts_with("GLOWCAP_ROOMS_BOT_UNKNOWN is set"), "{said}");
	assert!(!rig.dir.join("lock").exists(), "the refused serve took the lease");
}

/// A write that fails once as the first start stores what the session's first
/// answer vouched for is tried again with backoff, instead of ending the bot.
#[test]
fn a_failed_write_of_the_settings_and_link_is_tried_again_and_the_bot_serves() {
	let rig = Rig::new("bot-link-write-retry");
	let bot = rig.serve(json!({}), Some("link-write"));
	// The serving line comes from the retry's own save, and the log line that
	// says it worked follows it.
	super::rig::eventually("the retry to be logged", || {
		rig.log().contains(words::SAVED_ON_RETRY).then_some(())
	});
	let log = rig.log();
	assert!(
		log.contains(&format!("saving the settings and link {}", words::TRYING_AGAIN)),
		"{log}"
	);
	assert!(rig.dir.join("config.json").exists(), "the retry stored no settings");
	assert!(bot.stop().success(), "the bot ended with a failure");
}
