//! Relative gestures preserve explicit empty overrides and operate on one
//! admitted intent candidate. Coordinates remain existing custody selections.
use super::*;
use rooms_application::{content::session::local as gestures, session::command::Request};

fn apply(current: &workspace::Intent, name: &str, args: &[&str]) -> Result<workspace::Intent, gestures::Refusal> {
	use crate::arguments::Arg;
	let mut wire = vec![Arg::Text("gesture".into()), Arg::Integer(1), Arg::Text(name.into())];
	wire.extend(args.iter().map(|s| Arg::Text((*s).into())));
	let request = Request::parse(&wire).unwrap();
	assert!(gestures::recognizes(request.route()));
	assert!(requirements::command(request.route()).unwrap().targets.is_empty());
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
	assert!(apply(&initial, "chooseConnection", &["quic"]).is_err());
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
}
