use rooms_application::{
	grants::Access,
	session::checkpoint::{
		Checkpoint, Routes,
		commands::{self, Command, CommandRoutes},
		invitations::{RoomLink, RoomLinkInput},
	},
};

struct Captured(serde_json::Value);
impl Routes for Captured {
	fn locator_authority(&self, value: &str) -> Option<String> {
		self.0["locatorAuthorities"][value].as_str().map(str::to_owned)
	}
	fn sturdyref_authority(&self, value: &str) -> Option<String> {
		self.0["sturdyrefAuthorities"][value].as_str().map(str::to_owned)
	}
}
impl CommandRoutes for Captured {
	fn authority_token(&self, _: &str) -> Option<String> {
		None
	}
}
fn input<'a>(id: &'a str, link: &'a str) -> RoomLinkInput<'a> {
	RoomLinkInput {
		id,
		directory: "ocapn://directory.id",
		locator: "ocapn://directory.id",
		nick: "alice",
		label: "private room",
		from: "bob",
		link,
	}
}
pub fn run() {
	let routes = Captured(serde_json::from_str(include_str!("../fixtures/checkpoints.json")).unwrap());
	let link = "ocapn://directory.id/s/aW52aXRlZC1yb29t";
	let invite = RoomLink::new(input("received", link), &routes).unwrap();
	let empty = Checkpoint::empty();
	assert!(!invite.present(&empty));
	let received = commands::receive_room_link(&empty, &invite, &routes).unwrap();
	let wire = Command::ReceiveRoomLinkInvitation
		.apply(&empty, &[invite.encoded().unwrap()], &routes, &())
		.unwrap();
	assert_eq!(
		received.encode_for(Access::Admin).unwrap(),
		wire.encode_for(Access::Admin).unwrap()
	);
	assert!(invite.present(&received));
	assert!(
		RoomLink::new(input("duplicate", link), &routes)
			.unwrap()
			.present(&received)
	);
	assert!(
		RoomLink::new(input("received", "ocapn://directory.id/s/cm9vbS1saW5r"), &routes)
			.unwrap()
			.present(&received)
	);
	assert_eq!(
		invite.material().unwrap(),
		Command::ReceiveRoomLinkInvitation
			.material(&[invite.encoded().unwrap()])
			.unwrap()
	);
	assert!(RoomLink::new(input("bad", "ocapn://directory.id"), &routes).is_err());
	let mut bad = input("bad", link);
	bad.nick = "bob\n";
	assert!(RoomLink::new(bad, &routes).is_err());
	let huge = "x".repeat(65537);
	let mut bad = input("bad", link);
	bad.label = &huge;
	assert!(RoomLink::new(bad, &routes).is_err());
	let parsed: serde_json::Value = serde_json::from_str(&received.encode_for(Access::Admin).unwrap()).unwrap();
	assert!(parsed["conversations"].as_array().unwrap().is_empty());
	let observing: serde_json::Value = serde_json::from_str(&received.encode_for(Access::Observe).unwrap()).unwrap();
	assert_ne!(observing["invitations"][0]["link"], link);
}
