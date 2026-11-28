//! Relative gestures preserve explicit empty overrides and operate on one
//! admitted intent candidate. Coordinates remain existing custody selections.
use super::*;
use rooms_application::{content::session::local as gestures, session::command::Request};

fn apply(current: &workspace::Intent, name: &str, args: &[&str]) -> Result<workspace::Intent, gestures::Refusal> {
	gesture(current, name, args, false)
}
/// Apply one gesture to a copy of `current`. `targeted` says whether the
/// gesture selects existing custody, as `openDirect` selects a route.
fn gesture(
	current: &workspace::Intent,
	name: &str,
	args: &[&str],
	targeted: bool,
) -> Result<workspace::Intent, gestures::Refusal> {
	use crate::arguments::Arg;
	let mut wire = vec![Arg::Text("gesture".into()), Arg::Integer(1), Arg::Text(name.into())];
	wire.extend(args.iter().map(|s| Arg::Text((*s).into())));
	let request = Request::parse(&wire).unwrap();
	assert!(gestures::recognizes(request.route()));
	assert_eq!(
		requirements::command(request.route()).unwrap().targets.is_empty(),
		!targeted
	);
	let mut candidate = current.clone();
	gestures::apply(&request, &mut candidate, &mut custody::Custody::<References>::default())?;
	Ok(candidate)
}
fn room(intent: &workspace::Intent) -> &workspace::Room {
	let workspace::Conversation::Room(room) = &intent.conversations.as_slice()[0] else {
		panic!("room");
	};
	room
}
pub fn run() {
	let initial = workspace::Intent::decode(&fixture().to_string()).unwrap();
	let declared = apply(&initial, "setRoomProfile", &["conversation", "person", "Here today"]).unwrap();
	let mut restored = workspace::Intent::decode(&serde_json::to_string(&declared).unwrap()).unwrap();
	let workspace::Conversation::Room(returning) = &mut restored.conversations.as_mut_slice()[0] else {
		panic!("room")
	};
	returning.retire_connection();
	assert!(returning.seat.is_none());
	assert_eq!(
		returning.profile.about(),
		"Here today",
		"room intent survives retiring the old seat"
	);
	let cleared = apply(&restored, "setRoomProfile", &["conversation", "", ""]).unwrap();
	assert!(serde_json::to_value(room(&cleared)).unwrap().get("profile").is_none());
	assert!(apply(&initial, "setRoomProfile", &["conversation", "bogus", ""]).is_err());
	assert!(apply(&initial, "setRoomProfile", &["missing", "person", ""]).is_err());
	let draft = apply(&initial, "setDraft", &["conversation", "new draft"]).unwrap();
	assert_eq!(room(&draft).draft.text().as_str(), Some("new draft"));
	assert_eq!(room(&initial).draft.text().as_str(), Some("draft"));
	assert!(apply(&initial, "setDraft", &["missing", "draft"]).is_err());
	assert!(apply(&initial, "setDraft", &["conversation", &"x".repeat(4097)]).is_err());
	assert!(
		apply(&initial, "closeDirect", &["conversation"]).is_err(),
		"a room cannot become a closed direct"
	);
	let mut direct = fixture();
	direct["conversations"] = json!([{ "kind": "direct", "id": "direct", "directory": "directory", "peer": "peer", "access": null, "closed": true, "draft": "" }]);
	direct["active"] = json!("direct");
	let direct = workspace::Intent::decode(&direct.to_string()).unwrap();
	assert!(
		apply(&direct, "closeDirect", &["direct"])
			.unwrap()
			.conversations
			.as_slice()
			.iter()
			.all(|row| matches!(row, workspace::Conversation::Direct(d) if d.closed))
	);
	let selected = apply(&initial, "select", &[]).unwrap();
	assert!(selected.active.is_none());
	assert_eq!(
		apply(&selected, "select", &["conversation"]).unwrap().active,
		initial.active
	);
	assert!(apply(&initial, "select", &["missing"]).is_err());
	let global = apply(&initial, "setEffectiveStanding", &["conversation", "away"]).unwrap();
	assert_eq!(global.standing.text().as_str(), Some("away"));
	let directory = apply(&global, "setDirectoryStanding", &["directory", ""]).unwrap();
	assert_eq!(
		directory.directories.as_slice()[0]
			.standing
			.as_ref()
			.unwrap()
			.text()
			.as_str(),
		Some("")
	);
	let directory = apply(&directory, "setEffectiveStanding", &["conversation", "directory away"]).unwrap();
	assert_eq!(directory.standing, global.standing);
	assert_eq!(
		directory.directories.as_slice()[0]
			.standing
			.as_ref()
			.unwrap()
			.text()
			.as_str(),
		Some("directory away")
	);
	let room_override = apply(&directory, "setRoomStanding", &["conversation", "here"]).unwrap();
	let room_override = apply(&room_override, "setEffectiveStanding", &["conversation", "room away"]).unwrap();
	assert_eq!(
		room(&room_override).standing.as_ref().unwrap().text().as_str(),
		Some("room away")
	);
	assert_eq!(room_override.directories, directory.directories);
	let here = apply(&room_override, "setEffectiveStanding", &["conversation", ""]).unwrap();
	assert_eq!(room(&here).standing.as_ref().unwrap().text().as_str(), Some(""));
	assert_eq!(here.room_standing("conversation").unwrap().text().as_str(), Some(""));
	assert_eq!(here.directories, directory.directories);
	let here = apply(&directory, "setEffectiveStanding", &["conversation", ""]).unwrap();
	assert_eq!(
		here.directories.as_slice()[0]
			.standing
			.as_ref()
			.unwrap()
			.text()
			.as_str(),
		Some("")
	);
	assert_eq!(here.standing, global.standing);
	assert!(
		room(&apply(&room_override, "setRoomStanding", &["conversation"]).unwrap())
			.standing
			.is_none()
	);
	assert!(
		apply(&directory, "setDirectoryStanding", &["directory"])
			.unwrap()
			.directories
			.as_slice()[0]
			.standing
			.is_none()
	);
	let ignored = apply(&initial, "setIgnoredNames", &[r#"["PEER","peer","\ud800"]"#]).unwrap();
	let unchanged = apply(&ignored, "setIgnoredName", &["Peer", "true"]).unwrap();
	assert_eq!(ignored.ignored, unchanged.ignored);
	let ignored = apply(&ignored, "setIgnoredName", &["Peer", "false"]).unwrap();
	assert_eq!(ignored.ignored.as_slice().len(), 1);
	assert_eq!(
		ignored.ignored.as_slice()[0].text().utf16().collect::<Vec<_>>(),
		[0xd800]
	);
	let ignored = apply(&ignored, "setIgnoredName", &["NEIGHBOR", "true"]).unwrap();
	assert_eq!(ignored.ignored.as_slice()[1].text().as_str(), Some("neighbor"));
	assert!(apply(&initial, "setIgnoredName", &["peer", "yes"]).is_err());
	let retention = apply(&initial, "chooseHistoryRetention", &["false"]).unwrap();
	assert!(!retention.keep_history);
	assert!(apply(&initial, "chooseHistoryRetention", &["true", "bearer"]).is_err());
	let connection = apply(&initial, "chooseConnection", &["webrtc"]).unwrap();
	assert_eq!(connection.connection, workspace::Connection::Webrtc);
	for (word, choice) in [
		("fastest", workspace::Connection::Fastest),
		("relay", workspace::Connection::Relay),
	] {
		assert_eq!(apply(&initial, "chooseConnection", &[word]).unwrap().connection, choice);
	}
	assert!(apply(&initial, "chooseConnection", &["quic"]).is_err());
	// The saved word is the stored contract, so each choice keeps its own.
	for (word, choice) in [
		("fastest", workspace::Connection::Fastest),
		("webrtc", workspace::Connection::Webrtc),
		("relay", workspace::Connection::Relay),
	] {
		assert_eq!(serde_json::to_value(choice).unwrap(), serde_json::json!(word));
		assert_eq!(
			serde_json::from_value::<workspace::Connection>(word.into()).unwrap(),
			choice
		);
	}
	// The page resolves a preference against whether it has a Rooms server.
	use workspace::{Connection as C, DirectRoute as R};
	for (choice, with_server, without) in [
		(C::Fastest, R::Raced, R::Webrtc),
		(C::Webrtc, R::WebrtcThenRelay, R::Webrtc),
		(C::Relay, R::Relay, R::Relay),
	] {
		assert_eq!(choice.route(true), with_server, "{choice:?} with a server");
		assert_eq!(choice.route(false), without, "{choice:?} without one");
	}
	let homeless = apply(&initial, "chooseHomeDirectory", &[""]).unwrap();
	assert!(homeless.directories.as_slice().iter().all(|row| !row.home));
	let home = apply(&homeless, "chooseHomeDirectory", &["directory"]).unwrap();
	assert!(home.directories.as_slice()[0].home);
	assert!(apply(&initial, "chooseHomeDirectory", &["missing"]).is_err());
	assert!(apply(&initial, "chooseConnection", &["relay", "wss://elsewhere.test/"]).is_err());
	let mut redirected = fixture();
	redirected["traceOverride"] = "wss://elsewhere.test/".into();
	assert!(
		workspace::Intent::decode(&redirected.to_string()).is_err(),
		"endpoint text cannot redirect held trace authority"
	);
	let configured = apply(&workspace::Intent::empty(), "chooseConnection", &["webrtc"]).unwrap();
	let cleared = apply(&configured, "clearWorkspace", &[]).unwrap();
	assert_eq!(
		cleared.connection, configured.connection,
		"workspace reset preserves the peer's connection choice"
	);
	assert!(apply(&initial, "dismissInvitation", &["missing"]).is_err());
	direct_opening();
}

/// `openDirect` selects a row that is open, and reopens a closed one only
/// while no other open row reaches its registration.
fn direct_opening() {
	let row = |id: &str, closed: bool| {
		json!({ "kind": "direct", "id": id, "directory": "directory", "peer": "peer",
			"access": key::<custody::DirectAccess>(if closed { 2 } else { 3 }, 1), "closed": closed, "draft": "",
			"introduction": { "access": key::<custody::DirectoryAccess>(1, 1), "name": key::<custody::DirectoryAccess>(4, 1),
				"callback": key::<custody::DirectoryAccess>(5, 1), "registration": "member", "opening": id } })
	};
	let open = |current: &workspace::Intent, row: &[&str]| gesture(current, "openDirect", row, true);
	let mut both = fixture();
	both["conversations"] = json!([row("closed", true), row("open", false)]);
	let both = workspace::Intent::decode(&both.to_string()).unwrap();
	let selected = row("open", false).to_string();
	assert_eq!(
		open(&both, &[&selected]).unwrap().active.unwrap().text().as_str(),
		Some("open")
	);
	let mut reopening = row("closed", true);
	reopening["closed"] = false.into();
	assert_eq!(
		open(&both, &[&reopening.to_string()]),
		Err(gestures::Refusal::DirectOpen)
	);
	let mut alone = fixture();
	alone["conversations"] = json!([row("closed", true)]);
	let alone = workspace::Intent::decode(&alone.to_string()).unwrap();
	let reopened = open(&alone, &[&reopening.to_string()]).unwrap();
	assert!(matches!(&reopened.conversations.as_slice()[0], workspace::Conversation::Direct(row) if !row.closed));
	let mut another = row("another", false);
	another["access"] = serde_json::to_value(key::<custody::DirectAccess>(6, 1)).unwrap();
	assert_eq!(
		open(&reopened, &[&another.to_string()]),
		Err(gestures::Refusal::DirectOpen)
	);
}
