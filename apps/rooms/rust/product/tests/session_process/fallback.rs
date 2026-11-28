use super::session_rig::{Fixture, call, command, direct_message, ready, try_call};
use serde_json::json;

#[test]
fn join_bootstraps_only_an_empty_home_and_returns_memberships_without_the_workspace() {
	let fixture = Fixture::start("join-home", &["lead"], "workshop");
	let state = fixture.temp.join("scout");
	let mut session = command();
	session.args([
		format!("--state={}", state.display()),
		"--transport=tcp".into(),
		"--dial-transports=tcp".into(),
		"--local-control".into(),
	]);
	let (mut peer, _) = ready(session, "ROOMS-SESSION-LISTENING ");
	let mut options = json!({"home-locator":[fixture.locator],"nick":["scout"],"exact-nick":["true"]});
	let enrolled = json!({"ok":true,"joined":[]});
	assert_eq!(call(&state, "join", options.clone()), enrolled);
	call(
		&fixture.peers[0].state,
		"reply",
		json!({"dm":["scout"],"text":["private handoff"]}),
	);
	direct_message(&state, "private handoff");

	// Even an unparseable fallback must remain unused once a home is held.
	options["home-locator"] = json!(["http://["]);
	assert!(
		call(&state, "join", options.clone()) == enrolled,
		"directory enrollment exposed workspace state"
	);
	options["room"] = json!(["workshop"]);
	options["existing-room"] = json!(["true"]);
	let result = call(&state, "join", options.clone());
	let conversation = result["joined"][0]["conversation"].as_str().unwrap();
	assert!(
		result == json!({"ok":true,"joined":[{"room":"workshop","conversation":conversation}]}),
		"room enrollment exposed workspace state"
	);
	options["locator"] = json!([fixture.locator]);
	assert!(
		try_call(&state, "join", options)
			.unwrap_err()
			.contains("choose --locator or --home-locator")
	);
	assert!(
		try_call(&state, "join", json!({}))
			.unwrap_err()
			.contains("--room or --nick")
	);
	peer.signal("-TERM");
	fixture.finish();
}
