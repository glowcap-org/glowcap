use super::session_rig::{Fixture, call, direct_message};
use serde_json::json;

#[test]
fn team_status_summarizes_each_members_own_rooms_without_private_content() {
	let team = Fixture::start("team-status", &["scout", "editor"], "workshop");
	call(
		&team.temp,
		"team-start",
		json!({"lead":["scout"],"member":["editor"],"room":["workshop"],"locator":[team.locator]}),
	);
	call(
		&team.peers[0].state,
		"reply",
		json!({"dm":["editor"],"text":["private handoff"]}),
	);
	direct_message(&team.peers[1].state, "private handoff");
	call(&team.peers[1].state, "leave", json!({"room":["workshop"]}));

	let status = call(&team.temp, "team-status", json!({}));
	let members = status["members"].as_array().unwrap();
	assert_eq!(members.len(), 2);
	for (member, nick, rooms) in [
		(&members[0], "scout", json!([{"name":"workshop","joined":true}])),
		(&members[1], "editor", json!([])),
	] {
		let remaining = member["inbox"]["remaining"].as_u64().unwrap();
		assert!(
			*member == json!({"ok":true,"nick":nick,"rooms":rooms,"inbox":{"remaining":remaining,"gap":null}}),
			"team status must contain only the member's room membership and inbox summary"
		);
	}
	team.finish();
}
