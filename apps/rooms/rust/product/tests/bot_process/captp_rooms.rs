//! Real room membership from an attenuated bot grant and from an actual
//! direct invitation received while the session has no browser.
use super::captp::{World, action};
use super::captp_direct::{output, turn};
use super::rig::eventually;
use super::session_rig::{self, Fixture, call};
use serde_json::json;
use std::{path::Path, time::Duration};

fn offer(link: &str, operation: &str, room: &str, dm: &str) {
	session_rig::run_within(Duration::from_secs(30), async {
		let host = session_rig::host().await;
		let view = session_rig::attach(&host, link).await;
		let base = view.revision().await.unwrap();
		let result = view
			.command(operation, base, "offerRoom", &[room.to_owned(), dm.to_owned()])
			.await
			.unwrap();
		assert_eq!(result, rooms_services::session::attached::EffectStatus::Committed);
		host.close(glowcap::PendingWork::Cancel).await.unwrap();
	});
}

fn policy(state: &Path, directory: &str, mode: Option<&str>) -> serde_json::Value {
	let mut flags = json!({"directory":[directory]});
	if let Some(mode) = mode {
		flags["mode"] = json!([mode]);
	}
	call(state, "invitations", flags)["mode"].clone()
}

#[test]
fn a_collaborator_reads_only_this_rooms_live_members_and_their_own_introductions() {
	let world = World::new("bot-room-members");
	let room = world.fixture.room_id(0);
	let friend_room = world.fixture.room_id(1);
	let elsewhere = Fixture::start("members-another-directory", &["unrelated"], "unrelated-room");
	call(
		&world.fixture.peers[0].state,
		"join",
		json!({"locator":[elsewhere.locator],"nick":[super::captp::BOT],"room":["unrelated-room"]}),
	);

	let (link, grant) = session_rig::run_within(Duration::from_secs(40), async {
		let (issuer, grants, terms) = world.issuer().await;
		let issued = grants.issue("member reader", &terms).await.unwrap();
		let host = session_rig::host().await;
		let friend = session_rig::attach(&host, &world.fixture.peers[1].link).await;
		let args = [friend_room.clone(), "bot".to_owned(), "Looks up citations".to_owned()];
		assert_eq!(
			friend
				.command(
					"introduce-room-member",
					friend.revision().await.unwrap(),
					"setRoomProfile",
					&args
				)
				.await
				.unwrap(),
			rooms_services::session::attached::EffectStatus::Committed
		);
		loop {
			if friend
				.room_members(&friend_room)
				.await
				.unwrap()
				.iter()
				.any(|member| member.about == args[2])
			{
				break;
			}
			tokio::time::sleep(Duration::from_millis(75)).await;
		}
		host.close(glowcap::PendingWork::Cancel).await.unwrap();
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
		(issued.link, issued.name)
	});
	let bot = world.rig.serve_linked(&link, json!({}));
	let members = action("members", json!({}), &[]);
	assert_eq!(turn(&world, std::slice::from_ref(&members)), "exit=0");
	let answer = output(&world, 0);
	let rows = answer["members"].as_array().unwrap();
	assert_eq!(rows.len(), 2, "{answer}");
	assert!(
		rows.contains(&json!({"name":super::captp::FRIEND,"memberKind":"bot","about":"Looks up citations"})),
		"{answer}"
	);
	assert!(
		rows.contains(&json!({"name":super::captp::BOT,"memberKind":"","about":""})),
		"{answer}"
	);
	assert!(
		answer
			.as_object()
			.unwrap()
			.keys()
			.all(|key| matches!(key.as_str(), "members" | "ok"))
	);
	super::captp_direct::clear_outputs(&world);
	world.dm(&format!("act:{}", json!([members])));
	super::captp_crashes::answered(&world, "exit=1");
	let denied = output(&world, 0);
	assert!(
		denied["error"]["message"].as_str().unwrap().contains("turn in a room"),
		"{denied}"
	);
	assert!(denied.get("members").is_none());
	world.stopped(bot);
	session_rig::run_within(Duration::from_secs(20), async {
		let host = session_rig::host().await;
		let reader = session_rig::attach(&host, &link).await;
		let (issuer, grants, _) = world.issuer().await;
		grants.pause(&grant).await.unwrap();
		assert!(reader.room_members(&room).await.is_err());
		host.close(glowcap::PendingWork::Cancel).await.unwrap();
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
	});
	elsewhere.finish();
	world.finish();
}

#[test]
fn a_collaborator_joins_one_listed_room_in_one_turn_and_reuses_its_seat() {
	let world = World::new("bot-listed-room");
	let room = "second-listed-room";
	call(
		world.friend(),
		"join",
		json!({"locator":[world.fixture.locator],"nick":[super::captp::FRIEND],"room":[room]}),
	);
	let (link, grant) = super::session_rig::run_within(Duration::from_secs(30), async {
		let (issuer, grants, terms) = world.issuer().await;
		let issued = grants.issue("the bot", &terms).await.unwrap();
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
		(issued.link, issued.name)
	});
	let bot = world.rig.serve_linked(&link, json!({}));
	let join = action("join", json!({"room":[room]}), &[]);
	let response = turn(&world, &[join.clone(), join]);
	let first = output(&world, 0);
	assert_eq!(response, "exit=0 exit=0", "{first} {}", world.rig.evidence());
	let second = output(&world, 1);
	assert_eq!(first["status"], "joined", "{first}");
	assert_eq!(second["conversation"], first["conversation"], "{second}");
	let status = call(&world.fixture.peers[0].state, "status", json!({}));
	let rows: Vec<_> = status["workspace"]["conversations"]
		.as_array()
		.unwrap()
		.iter()
		.filter(|row| row["name"] == room)
		.collect();
	assert_eq!(rows.len(), 1);
	assert!(rows[0]["seat"].is_string() && rows[0]["inbox"].is_string());
	assert!(rows[0]["control"].is_null() && rows[0]["moderator"].is_null());
	let missing = action("join", json!({"room":["absent-listing"]}), &[]);
	assert_eq!(turn(&world, &[missing]), "exit=1");
	let refusal = output(&world, 0);
	assert!(
		refusal["error"]["message"]
			.as_str()
			.is_some_and(|text| text.contains("no listed room")),
		"{refusal}"
	);
	let after = call(&world.fixture.peers[0].state, "status", json!({}));
	assert!(
		!after["workspace"]["conversations"]
			.as_array()
			.unwrap()
			.iter()
			.any(|row| row["name"] == "absent-listing")
	);

	let other_entrance = action("join", json!({"room":[super::captp::ROOM]}), &[]);
	assert_eq!(turn(&world, &[other_entrance]), "exit=1");
	let original = output(&world, 0);
	assert!(
		original["error"]["message"]
			.as_str()
			.is_some_and(|text| text.contains("another entrance")),
		"{original}"
	);
	world.stopped(bot);
	// A second, live caller cannot claim the saved seat is ready after the grant
	// that established its callback has been paused.
	session_rig::run_within(Duration::from_secs(40), async {
		let (issuer, grants, _) = world.issuer().await;
		grants.pause(&grant).await.unwrap();
		let caller = session_rig::host().await;
		let active = session_rig::attach(&caller, &world.fixture.peers[0].link).await;
		assert!(active.join_listed(&world.fixture.room_id(0), room).await.is_err());
		caller.close(glowcap::PendingWork::Cancel).await.unwrap();
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}

#[test]
fn an_operator_selected_directory_accepts_an_invite_on_a_collaborators_dm_without_a_browser() {
	let mut world = World::new("bot-native-invite");
	let room = "offered-room";
	let friend = world.friend();
	let state = world.fixture.peers[0].state.clone();
	let bot_state = state.as_path();
	let opened = call(
		friend,
		"join",
		json!({"locator":[world.fixture.locator],"nick":[super::captp::FRIEND],"room":[room]}),
	);
	let offered = opened["joined"][0]["conversation"].as_str().unwrap().to_owned();
	let directory = call(bot_state, "status", json!({}))["workspace"]["directories"][0]["id"]
		.as_str()
		.unwrap()
		.to_owned();
	assert_eq!(policy(bot_state, &directory, None), "review");
	let link = super::session_rig::run_within(Duration::from_secs(30), async {
		let (issuer, grants, terms) = world.issuer().await;
		let link = grants.issue("the bot", &terms).await.unwrap().link;
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
		link
	});
	let bot = world.rig.serve_linked(&link, json!({}));
	let request = "send me the invitation";
	assert_eq!(
		turn(
			&world,
			&[action(
				"say",
				json!({"dm":[super::captp::FRIEND],"text":[request]}),
				&[]
			)]
		),
		"exit=0"
	);
	assert_eq!(policy(bot_state, &directory, Some("auto")), "auto");
	let dm = session_rig::direct_message(friend, request);
	let snapshot = call(friend, "status", json!({}));
	let row = snapshot["workspace"]["conversations"]
		.as_array()
		.unwrap()
		.iter()
		.find(|row| row["id"] == dm)
		.unwrap();
	// The incoming line can arrive before the friend's reply capability.
	session_rig::wait_for_return_route(friend, row["introduction"]["opening"].as_str().unwrap());
	let sender = &world.fixture.peers[1].link;
	offer(sender, "invite-collaborator", &offered, &dm);
	let seat = eventually("the invited session's exact offered room seat", || {
		let state = call(bot_state, "status", json!({}));
		let row = state["workspace"]["conversations"]
			.as_array()?
			.iter()
			.find(|r| r["name"] == room && r["seat"].is_string())?;
		assert_eq!(row["directory"], directory);
		assert!(row["control"].is_null() && row["moderator"].is_null() && row["access"].is_string());
		Some((row["id"].clone(), row["seat"].clone()))
	});
	// A second server gives the session a real, independently registered directory.
	let other = Fixture::start("other-invitation-directory", &["neighbor"], "other-private-work");
	call(
		bot_state,
		"join",
		json!({"locator":[other.locator],"nick":[super::captp::BOT]}),
	);
	let neighbor = &other.peers[0];
	let intro = call(
		&neighbor.state,
		"reply",
		json!({"dm":[super::captp::BOT],"text":["second directory invitation"]}),
	);
	assert_eq!(intro["status"], "committed");
	let second_dm = session_rig::direct_message(bot_state, "second directory invitation");
	let remote = call(&neighbor.state, "status", json!({}));
	let contact = remote["workspace"]["conversations"]
		.as_array()
		.unwrap()
		.iter()
		.find(|r| r["kind"] == "direct" && r["closed"] != true)
		.unwrap()["id"]
		.as_str()
		.unwrap();
	let other_room = other.room_id(0);
	offer(&neighbor.link, "offer-from-other-directory", &other_room, contact);
	eventually("the unselected directory's actual offer arriving", || {
		let pending = call(bot_state, "tick", json!({"wait":["0"]}));
		pending["pending"]
			.as_array()?
			.iter()
			.any(|row| {
				row["event"]["target"]["id"] == second_dm && row["event"]["notice"]["label"] == "other-private-work"
			})
			.then_some(())
	});
	offer(sender, "second-independent-invitation", &offered, &dm);
	eventually("the second same-name offer retained for review", || {
		let status = call(bot_state, "status", json!({}));
		let workspace = &status["workspace"];
		workspace["invitations"]
			.as_array()?
			.iter()
			.find(|r| r["label"] == room)?;
		let rows = workspace["conversations"].as_array()?;
		let seated: Vec<_> = rows.iter().filter(|r| r["name"] == room).collect();
		assert_eq!(seated.len(), 1);
		assert_eq!((seated[0]["id"].clone(), seated[0]["seat"].clone()), seat);
		assert!(!rows.iter().any(|r| r["name"] == "other-private-work"));
		Some(())
	});
	call(
		world.friend(),
		"reply",
		json!({"room":[room],"text":["@bot-host reply:still here"]}),
	);
	world.await_line("room", "still here");
	assert_eq!(policy(bot_state, &directory, Some("review")), "review");
	world.stopped(bot);
	world.fixture.peers[0].restart();
	assert_eq!(policy(bot_state, &directory, None), "review");
	eventually("the restarted receiving directory to register its contact", || {
		let peer_state = call(bot_state, "status", json!({}));
		peer_state["workspace"]["directories"].as_array()?.iter().find(|row| {
			row["id"] == directory && row["assignedNick"] == super::captp::BOT && row["inbox"].is_string()
		})?;
		Some(())
	});
	world.dm("invitation after restart");
	session_rig::direct_message(bot_state, "invitation after restart");
	let after = call(
		world.friend(),
		"join",
		json!({"locator":[world.fixture.locator],"nick":[super::captp::FRIEND],"room":["review-after-restart"]}),
	);
	let newer_dm = call(world.friend(), "status", json!({}))["workspace"]["conversations"]
		.as_array()
		.unwrap()
		.iter()
		.find(|r| r["kind"] == "direct" && r["closed"] != true)
		.unwrap()["id"]
		.as_str()
		.unwrap()
		.to_owned();
	offer(
		&world.fixture.peers[1].link,
		"offer-after-restart",
		after["joined"][0]["conversation"].as_str().unwrap(),
		&newer_dm,
	);
	eventually("the review-mode invitation received after restart", || {
		let pending = call(bot_state, "tick", json!({"wait":["0"]}));
		pending["pending"]
			.as_array()?
			.iter()
			.any(|row| row["event"]["notice"]["label"] == "review-after-restart")
			.then_some(())
	});
	let review = call(bot_state, "status", json!({}));
	assert!(
		!review["workspace"]["conversations"]
			.as_array()
			.unwrap()
			.iter()
			.any(|r| r["name"] == "review-after-restart")
	);
	other.finish();
	world.finish();
}
