use super::*;
use crate::session::checkpoint::Routes;
use alloc::string::String;
struct Addresses;
impl Routes for Addresses {
	fn locator_authority(&self, locator: &str) -> Option<String> {
		Some(locator.into())
	}
	fn sturdyref_authority(&self, _: &str) -> Option<String> {
		None
	}
}
impl CommandRoutes for Addresses {
	fn authority_token(&self, _: &str) -> Option<String> {
		None
	}
}
#[test]
fn registration_retirement_closes_only_the_exact_durable_direct_intent() {
	let checkpoint = Checkpoint::decode(r#"{"version":1,"directories":[{"id":"directory","locator":"directory","home":true,"nick":"","standing":null}],"conversations":[{"kind":"direct","id":"conversation","directory":"directory","peer":"bob","peerRegistrationId":"00000000-0000-0000-0000-000000000000","closed":false,"draft":"unsent"}],"invitations":[],"active":null,"standing":"","ignored":[],"keepHistory":true,"join":{"room":"","locator":"","nick":""},"dmMode":"webrtc","capabilities":{"operations":[],"archivePeer":null},"peering":[]}"#, &Addresses).unwrap();
	let fact = |peer: &str| Fact::DirectRegistrationRetired {
		conversation: Id::new("conversation".into()).unwrap(),
		directory: Id::new("directory".into()).unwrap(),
		peer: Id::new(peer.into()).unwrap(),
		registration: Field::new("00000000-0000-0000-0000-000000000000".into()).unwrap(),
	};
	assert!(fact("mallory").apply(&checkpoint, &Addresses).unwrap().is_none());
	let retired = fact("bob").apply(&checkpoint, &Addresses).unwrap().unwrap();
	let Conversation::Direct(direct) = &retired.0.conversations.0[0] else {
		panic!("direct entry")
	};
	assert!(direct.closed);
	assert_eq!(direct.draft.text().as_str(), Some("unsent"));
	assert!(fact("bob").apply(&retired, &Addresses).unwrap().is_none());
}
