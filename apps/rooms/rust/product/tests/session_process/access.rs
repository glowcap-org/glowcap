//! The access verbs a person at a terminal uses, run through the real session
//! executable's control path against a running session. Another Host attaches
//! with the printed link, so the proof reaches what the access allows. The
//! session keeps each control in its workspace rows, so an access is managed
//! by the id the list shows, with nothing kept from the issue's output.
use super::session_rig::{Fixture, LinkSecret, attach, call, free_port, host, run_within, text_arrived};
use glowcap::PendingWork;
use rooms_application::content::session::{Preset, Terms};
use rooms_platform::HostPlatform;
use rooms_services::session::attached::{EffectStatus, Error, Grants, Lifecycle, State, View};
use serde_json::{Value, json};
use std::{path::Path, time::Duration};

/// One control request to completion, with its stdout and stderr kept apart.
fn request(state: &Path, verb: &str, named: Value) -> (bool, String, String) {
	let options = json!({"verb": format!("access-{verb}"), "state": state, "named": named, "arguments": []});
	let output = super::command()
		.args(["control", &options.to_string()])
		.output()
		.unwrap();
	(
		output.status.success(),
		String::from_utf8(output.stdout).unwrap(),
		String::from_utf8(output.stderr).unwrap(),
	)
}

fn access(state: &Path, verb: &str, named: Value) -> Value {
	let (ok, stdout, stderr) = request(state, verb, named.clone());
	assert!(ok, "access {verb} {named}: {stderr}");
	assert_eq!(
		stdout.lines().count(),
		1,
		"access {verb} printed more than one JSON line"
	);
	serde_json::from_str(&stdout).unwrap()
}

fn row(state: &Path, label: &str) -> Value {
	let listed = access(state, "list", json!({}));
	let mut rows = listed["accesses"]
		.as_array()
		.unwrap()
		.iter()
		.filter(|row| row["label"] == label);
	let row = rows
		.next()
		.cloned()
		.unwrap_or_else(|| panic!("no access labeled {label}: {listed}"));
	assert!(rows.next().is_none(), "two accesses labeled {label}: {listed}");
	row
}

/// The id the list shows for the access labeled `label`.
fn listed_id(state: &Path, label: &str) -> String {
	row(state, label)["id"]
		.as_str()
		.unwrap_or_else(|| panic!("the access labeled {label} has no id"))
		.to_owned()
}

#[test]
fn a_person_issues_lists_pauses_resumes_and_revokes_access_from_the_terminal() {
	let fixture = Fixture::start("access-verbs", &["access-one", "access-two"], "access-room");
	let (one, two) = (&fixture.peers[0], &fixture.peers[1]);
	let (ok, stdout, stderr) = request(
		&one.state,
		"issue",
		json!({"label": ["the bot"], "rights": ["collaborator"]}),
	);
	assert!(ok, "{stderr}");
	let issued: Value = serde_json::from_str(&stdout).unwrap();
	let link = issued["link"].as_str().unwrap().to_owned();
	let id = issued["id"].as_str().unwrap().to_owned();
	assert_eq!(issued["label"], "the bot");
	let fields: Vec<&String> = issued.as_object().unwrap().keys().collect();
	assert_eq!(fields.len(), 5, "{fields:?}");
	let secret = LinkSecret::of(&link);
	secret.assert_absent(&stderr, "the issue's stderr");
	// A refused value is refused exactly, before anything is issued.
	for rights in ["root", "Observer", ""] {
		let (ok, stdout, stderr) = request(&one.state, "issue", json!({"label": ["x"], "rights": [rights]}));
		assert!(!ok, "{rights:?} was accepted");
		secret.assert_absent(&stdout, "a refused issue's output");
		secret.assert_absent(&stderr, "a refused issue's stderr");
		assert!(stdout.contains("--rights"), "{stdout}");
	}
	let (ok, stdout, _) = request(&one.state, "issue", json!({"label": ["x"]}));
	// An accepted issue printed a link, so only a refusal's output is shown.
	assert!(!ok, "an issue without --rights was accepted");
	assert!(stdout.contains("--rights is required"), "{stdout}");
	let listed = row(&one.state, "the bot");
	assert_eq!(listed["id"], id.as_str());
	secret.assert_absent(listed.to_string(), "the access list");
	assert_eq!(
		(listed["state"].clone(), listed["effective"].clone()),
		(json!("active"), json!("active"))
	);
	assert!(
		listed["rights"]
			.as_array()
			.unwrap()
			.contains(&json!("interactWorkspace"))
	);
	run_within(Duration::from_secs(60), async {
		let holder = host().await;
		let view = attach(&holder, &link).await;
		let room = fixture.room_id(0);
		let said = view
			.say("access-say-1", &room, "from the terminal's access")
			.await
			.unwrap();
		assert_eq!(said.status, EffectStatus::Committed);
		text_arrived(&two.state, "from the terminal's access");
		let named = || json!({"id": [id]});
		access(&one.state, "pause", named());
		assert!(matches!(
			view.say("access-say-2", &room, "paused").await,
			Err(Error::Paused)
		));
		assert_eq!(row(&one.state, "the bot")["state"], "paused");
		access(&one.state, "resume", named());
		let again = view.say("access-say-3", &room, "resumed").await.unwrap();
		assert_eq!(again.status, EffectStatus::Committed);
		assert_eq!(row(&one.state, "the bot")["state"], "active");
		access(&one.state, "revoke", named());
		assert!(matches!(
			view.say("access-say-4", &room, "revoked").await,
			Err(Error::Revoked)
		));
		assert_eq!(row(&one.state, "the bot")["state"], "revoked");
		// A revoked access no longer names its control. Its row saved the
		// inventory entry it manages, so the list still shows it once, by id.
		let revoked = row(&one.state, "the bot");
		assert_eq!(
			(&revoked["id"], &revoked["saved"], &revoked["state"]),
			(&json!(id), &json!(true), &json!("revoked"))
		);
		let listed = access(&one.state, "list", json!({}));
		let kept = listed["accesses"]
			.as_array()
			.unwrap()
			.iter()
			.filter(|row| row["id"] == id.as_str())
			.count();
		assert_eq!(kept, 1, "{listed}");
		let (ok, stdout, _) = request(&one.state, "pause", named());
		assert!(!ok && stdout.contains("revoked"), "{stdout}");
		access(&one.state, "revoke", named());
		holder.close(PendingWork::Cancel).await.unwrap();
	});
	fixture.finish();
}

#[test]
fn an_access_whose_output_was_lost_is_managed_by_the_id_the_list_shows() {
	let fixture = Fixture::start("access-lost", &["lost-one", "lost-two"], "lost-room");
	let (one, two) = (&fixture.peers[0], &fixture.peers[1]);
	let links: Vec<String> = ["first", "second"]
		.iter()
		.map(|label| {
			let issued = access(
				&one.state,
				"issue",
				json!({"label": [label], "rights": ["collaborator"]}),
			);
			issued["link"].as_str().unwrap().to_owned()
		})
		.collect();
	// Only the holders keep the links. The operator kept nothing else.
	let first = listed_id(&one.state, "first");
	let second = listed_id(&one.state, "second");
	assert_ne!(first, second);
	// The session keeps both in the workspace rows the page lists.
	let status = call(&one.state, "status", json!({}));
	let kept: Vec<_> = status["workspace"]["accesses"]
		.as_array()
		.unwrap()
		.iter()
		.filter_map(|row| row["id"].as_str())
		.collect();
	assert!(
		kept.contains(&first.as_str()) && kept.contains(&second.as_str()),
		"{status}"
	);
	access(&one.state, "revoke", json!({"id": [first]}));
	run_within(Duration::from_secs(60), async {
		let holder = host().await;
		let room = fixture.room_id(0);
		let revoked = View::attach(&holder, HostPlatform, &links[0]).await;
		assert!(matches!(revoked, Err(Error::Revoked)), "{:?}", revoked.err());
		let kept = attach(&holder, &links[1]).await;
		let said = kept
			.say("lost-say-1", &room, "the second access still works")
			.await
			.unwrap();
		assert_eq!(said.status, EffectStatus::Committed);
		text_arrived(&two.state, "the second access still works");
		holder.close(PendingWork::Cancel).await.unwrap();
	});
	// Forgetting is for a revoked access only, and frees its row.
	let (ok, stdout, _) = request(&one.state, "forget", json!({"id": [second]}));
	assert!(!ok && stdout.contains("Revoke it before forgetting it"), "{stdout}");
	access(&one.state, "forget", json!({"id": [first]}));
	let listed = access(&one.state, "list", json!({}));
	let ids: Vec<_> = listed["accesses"]
		.as_array()
		.unwrap()
		.iter()
		.map(|row| row["id"].clone())
		.collect();
	assert!(!ids.contains(&json!(first)) && ids.contains(&json!(second)), "{listed}");
	let (ok, stdout, _) = request(&one.state, "revoke", json!({"id": [first]}));
	assert!(!ok && stdout.contains("session access list"), "{stdout}");
	fixture.finish();
}

#[test]
fn an_issue_the_session_stopped_in_the_middle_of_is_finished_by_issuing_again() {
	let mut fixture = Fixture::start_on(
		"access-unfinished",
		&["unfinished-one", "unfinished-two"],
		"unfinished-room",
		&[free_port(), 0],
	);
	let state = fixture.peers[0].state.clone();
	let named = || json!({"id": ["kept-bot"], "label": ["the bot"], "rights": ["collaborator"]});
	fixture.peers[0].restart_at(Some("after-issue"));
	let (ok, _, stderr) = request(&state, "issue", named());
	assert!(!ok, "the session finished an issue it was to stop in: {stderr}");
	assert!(
		!fixture.peers[0].process.wait().success(),
		"the session was not stopped after the issue"
	);
	fixture.peers[0].relaunch(None);

	// The row was saved before the issue, so the access that was made is
	// paused and found through it.
	let listed = access(&state, "list", json!({}));
	let rows = listed["accesses"].as_array().unwrap();
	let unfinished: Vec<_> = rows.iter().filter(|row| row["id"] == "kept-bot").collect();
	assert_eq!(unfinished.len(), 1, "{listed}");
	assert_eq!(unfinished[0]["state"], "unfinished", "{listed}");
	let made = row(&state, "the bot");
	assert_eq!((&made["state"], &made["saved"]), (&json!("paused"), &json!(false)));

	let (ok, conflict, _) = request(
		&state,
		"issue",
		json!({"id":["another-bot"], "label":["another"], "rights":["observer"]}),
	);
	assert!(
		!ok && conflict.contains("kept-bot"),
		"a new issue must preserve the unfinished issue's receipt"
	);

	let issued = access(&state, "issue", named());
	let link = issued["link"].as_str().unwrap().to_owned();
	assert_eq!(issued["id"], "kept-bot");
	// One access labeled the bot: the issue was finished, not repeated.
	let finished = row(&state, "the bot");
	assert_eq!(
		(&finished["id"], &finished["state"], &finished["saved"]),
		(&json!("kept-bot"), &json!("active"), &json!(true))
	);
	let status = call(&state, "status", json!({}));
	let saved = status["workspace"]["accesses"]
		.as_array()
		.unwrap()
		.iter()
		.find(|row| row["id"] == "kept-bot")
		.cloned()
		.unwrap_or_else(|| panic!("{status}"));
	assert_eq!(
		saved["issue"],
		json!({"saved": {"slot": finished["slot"], "generation": finished["generation"]}}),
		"the row did not save the inventory entry it manages"
	);
	run_within(Duration::from_secs(60), async {
		let holder = host().await;
		let view = attach(&holder, &link).await;
		let room = fixture.room_id(0);
		let said = view.say("unfinished-say", &room, "finished at last").await.unwrap();
		assert_eq!(said.status, EffectStatus::Committed);
		text_arrived(&fixture.peers[1].state, "finished at last");
		holder.close(PendingWork::Cancel).await.unwrap();
	});
	access(&state, "revoke", json!({"id": ["kept-bot"]}));
	access(&state, "forget", json!({"id": ["kept-bot"]}));
	let listed = access(&state, "list", json!({}));
	assert!(
		listed["accesses"]
			.as_array()
			.unwrap()
			.iter()
			.all(|row| row["id"] != "kept-bot"),
		"{listed}"
	);

	// A row whose issue stopped can be dropped instead of finished. Its
	// access stays paused and listed without an id.
	fixture.peers[0].restart_at(Some("after-issue"));
	let lost = || json!({"id": ["lost-bot"], "label": ["the lost bot"], "rights": ["observer"]});
	let (ok, _, _) = request(&state, "issue", lost());
	assert!(!ok);
	assert!(!fixture.peers[0].process.wait().success());
	fixture.peers[0].relaunch(None);
	let forgotten = access(&state, "forget", json!({"id": ["lost-bot"]}));
	assert!(
		forgotten["note"].as_str().unwrap().contains("session access list"),
		"{forgotten}"
	);
	let left = row(&state, "the lost bot");
	assert_eq!(
		(&left["id"], &left["state"]),
		(&Value::Null, &json!("paused")),
		"{left}"
	);
	fixture.finish();
}

#[test]
fn a_failed_save_leaves_a_replayed_grant_usable_and_recoverable() {
	use rooms_glowcap::client::{Client, access::Control};
	use rooms_services::session::attached::{change, describe, issue_under};

	let mut fixture = Fixture::start_on("access-save", &["save-one", "save-two"], "save-room", &[free_port(), 0]);
	let state = fixture.peers[0].state.clone();
	let named = || json!({"id": ["bot"], "label": ["the bot"], "rights": ["observer"]});
	fixture.peers[0].restart_at(Some("after-issue-reservation"));
	assert!(!request(&state, "issue", named()).0);
	assert!(!fixture.peers[0].process.wait().success());
	fixture.peers[0].relaunch(Some("fail-access-save"));
	let management = std::fs::read_to_string(state.join("management.sturdyref")).unwrap();
	run_within(Duration::from_secs(30), async {
		let holder = host().await;
		let parsed = glowcap::parse_sturdyref(management.trim(), glowcap::CaptpVersion::V1_0).unwrap();
		let connection = holder.connect(&parsed.locator, Default::default()).await.unwrap();
		let reference = connection
			.fetch(std::str::from_utf8(&parsed.swissnum).unwrap())
			.await
			.unwrap();
		let client = Client::new(connection, HostPlatform);
		let root = Control::new(client.clone(), reference);
		let rights = Terms::new(Preset::Observer.values()).unwrap();
		let issued = issue_under(&root, "the bot", &rights, true).await.unwrap();
		let control = Control::new(client, issued.control);
		change(&control, Lifecycle::Resume).await.unwrap();
		let (ok, refused, _) = request(&state, "issue", named());
		assert!(!ok && refused.contains("could not confirm"), "{refused}");
		assert_eq!(describe(&control).await.unwrap().unwrap().effective, State::Active);
		holder.close(PendingWork::Cancel).await.unwrap();
	});
	let before = row(&state, "the bot");
	assert_eq!(before["saved"], false);
	fixture.peers[0].restart_at(None);
	access(&state, "issue", named());
	let after = row(&state, "the bot");
	assert_eq!(after["id"], "bot");
	assert_eq!(
		(&after["slot"], &after["generation"]),
		(&before["slot"], &before["generation"])
	);
	fixture.finish();
}

#[test]
fn an_external_issuer_can_use_or_age_out_the_place_a_terminal_reserved() {
	let mut fixture = Fixture::start_on(
		"access-moved",
		&["moved-one", "moved-two"],
		"moved-room",
		&[free_port(), 0],
	);
	let state = fixture.peers[0].state.clone();
	let named = || json!({"id": ["terminal-bot"], "label": ["terminal"], "rights": ["observer"]});
	fixture.peers[0].restart_at(Some("after-issue-reservation"));
	assert!(!request(&state, "issue", named()).0);
	assert!(!fixture.peers[0].process.wait().success());
	fixture.peers[0].relaunch(None);
	let management = std::fs::read_to_string(state.join("management.sturdyref")).unwrap();
	run_within(Duration::from_secs(30), async {
		let holder = host().await;
		let grants = Grants::attach(&holder, HostPlatform, management.trim()).await.unwrap();
		let rights = Terms::new(Preset::Observer.values()).unwrap();
		let external = grants.issue("another issuer", &rights).await.unwrap();
		let (ok, conflict, _) = request(&state, "issue", named());
		assert!(
			!ok && conflict.contains("different request") && conflict.contains("forget"),
			"{conflict}"
		);
		for i in 0..8 {
			grants.issue(&format!("new grant {i}"), &rights).await.unwrap();
		}
		let (ok, expired, _) = request(&state, "issue", named());
		assert!(
			!ok && expired.contains("expired") && expired.contains("forget"),
			"{expired}"
		);
		access(&state, "forget", json!({"id":["terminal-bot"]}));
		access(&state, "issue", named());
		assert_eq!(grants.grant(&external.name).await.unwrap().effective, State::Active);
		holder.close(PendingWork::Cancel).await.unwrap();
	});
	fixture.finish();
}

#[test]
fn an_unfinished_reservation_belongs_to_one_access_id_across_restart() {
	let mut fixture = Fixture::start_on(
		"access-reserved",
		&["reserved-one", "reserved-two"],
		"reserved-room",
		&[free_port(), 0],
	);
	let state = fixture.peers[0].state.clone();
	let issue = |id: &str| json!({"id": [id], "label": ["the bot"], "rights": ["observer"]});
	fixture.peers[0].restart_at(Some("after-issue-reservation"));
	assert!(!request(&state, "issue", issue("first")).0);
	assert!(!fixture.peers[0].process.wait().success());
	fixture.peers[0].relaunch(None);
	let (ok, failure, _) = request(&state, "issue", issue("second"));
	assert!(
		!ok && failure.contains("first"),
		"the second issue should name the unfinished reservation"
	);
	let first = access(&state, "issue", issue("first"));
	let second = access(&state, "issue", issue("second"));
	assert!(
		first["link"] != second["link"],
		"distinct ids must issue distinct accesses"
	);
	access(&state, "revoke", json!({"id": ["first"]}));
	let list = access(&state, "list", json!({}));
	let rows = list["accesses"].as_array().unwrap();
	for (id, expected) in [("first", "revoked"), ("second", "active")] {
		assert!(
			rows.iter().any(|row| row["id"] == id && row["effective"] == expected),
			"{list}"
		);
	}
	std::thread::scope(|scope| {
		let third = scope.spawn(|| access(&state, "issue", issue("third")));
		let fourth = access(&state, "issue", issue("fourth"));
		assert!(
			third.join().unwrap()["link"] != fourth["link"],
			"concurrent issues must have independent access"
		);
	});
	fixture.finish();
}

#[test]
fn access_commands_say_when_no_session_is_running() {
	let temp = rooms_testing::scratch::Scratch::create("access-none");
	let (ok, stdout, _) = request(&temp, "list", json!({}));
	assert!(!ok);
	assert!(stdout.contains("no session is running"), "{stdout}");
}

/// A person hands one access's management to another place, such as a
/// browser's session access list. The link manages that one access with the
/// powers its control was issued with, and the session keeps managing it too.
#[test]
fn a_shared_management_link_manages_the_one_access_it_names() {
	let fixture = Fixture::start("access-share", &["share-one", "share-two"], "share-room");
	let one = &fixture.peers[0];
	let issue = |label: &str| access(&one.state, "issue", json!({"label": [label], "rights": ["observer"]}));
	let shared = issue("shared");
	issue("other");
	let named = |issued: &Value| json!({"id": [issued["id"].as_str().unwrap()]});
	let (ok, stdout, stderr) = request(&one.state, "share-management", named(&shared));
	assert!(ok, "{stderr}");
	assert_eq!(stdout.lines().count(), 1, "the link is printed on one JSON line");
	let answer: Value = serde_json::from_str(&stdout).unwrap();
	let link = answer["link"].as_str().unwrap().to_owned();
	assert_eq!(answer["id"], shared["id"]);
	let secret = LinkSecret::of(&link);
	secret.assert_absent(&stderr, "the share's stderr");
	secret.assert_absent(access(&one.state, "list", json!({})).to_string(), "the access list");
	assert_ne!(link, shared["link"], "the management link is not the use link");
	// Sharing again names the same control, so a lost link is read again.
	assert_eq!(
		access(&one.state, "share-management", named(&shared))["link"],
		link.as_str()
	);
	run_within(Duration::from_secs(60), async {
		let holder = host().await;
		let grants = Grants::attach(&holder, HostPlatform, &link).await.unwrap();
		let held = grants.own().await.unwrap().expect("the shared access is live");
		assert_eq!((held.label.as_str(), held.state), ("shared", State::Active));
		grants.change_own(Lifecycle::Pause).await.unwrap();
		assert_eq!(row(&one.state, "shared")["state"], "paused");
		assert_eq!(row(&one.state, "other")["state"], "active");
		// The control was issued to change one access's lifecycle and no more.
		let terms = Terms::new(Preset::Observer.values()).unwrap();
		assert!(grants.issue("wider", &terms).await.is_err());
		access(&one.state, "resume", named(&shared));
		assert_eq!(grants.own().await.unwrap().unwrap().state, State::Active);
		grants.change_own(Lifecycle::Revoke).await.unwrap();
		assert_eq!(row(&one.state, "shared")["state"], "revoked");
		assert_eq!(row(&one.state, "other")["state"], "active");
		holder.close(PendingWork::Cancel).await.unwrap();
	});
	let (ok, stdout, _) = request(&one.state, "share-management", named(&shared));
	assert!(!ok && stdout.contains("revoked"), "{stdout}");
	let (ok, stdout, _) = request(&one.state, "share-management", json!({"id": ["no-such-access"]}));
	assert!(!ok && stdout.contains("no access is kept"), "{stdout}");
	fixture.finish();
}

#[test]
fn a_view_reuses_its_typing_sender_when_every_reader_place_is_held() {
	let fixture = Fixture::start("access-typing", &["typing-one", "typing-two"], "typing-room");
	let one = &fixture.peers[0];
	let issued = access(
		&one.state,
		"issue",
		json!({"label": ["bot"], "rights": ["collaborator"]}),
	);
	let link = issued["link"].as_str().unwrap().to_owned();
	run_within(Duration::from_secs(120), async {
		let holder = host().await;
		let parsed = glowcap::parse_sturdyref(&link, glowcap::CaptpVersion::V1_0).unwrap();
		let connection = holder.connect(&parsed.locator, Default::default()).await.unwrap();
		let reference = connection
			.fetch(std::str::from_utf8(&parsed.swissnum).unwrap())
			.await
			.unwrap();
		let client = rooms_glowcap::client::Client::new(connection, HostPlatform);
		let view = View::attach_reference(client.clone(), reference.clone()).await.unwrap();
		let workspace = rooms_glowcap::client::workspace::Workspace::new(client, reference);
		let room = fixture.room_id(0);
		view.typing(&room, true).await.unwrap();
		// Hold each activity reader the session gives us. Once the
		// last place is taken, only the first view's existing sender can signal.
		let mut held = Vec::new();
		let limit = glowcap::loam::Limits::default().max_continuations;
		for _ in 0..=limit {
			match workspace.activity_reader().await {
				Ok(reader) => held.push(reader),
				Err(error) => {
					assert!(error.to_string().contains("ContinuationCapacity"), "{error}");
					break;
				}
			}
		}
		assert!(!held.is_empty() && held.len() < limit);
		if let Err(error) = view.typing(&room, false).await {
			assert!(error.to_string().contains("rate-limited"), "{error}");
		}
		drop(held);
		holder.close(PendingWork::Cancel).await.unwrap();
	});
	fixture.finish();
}
