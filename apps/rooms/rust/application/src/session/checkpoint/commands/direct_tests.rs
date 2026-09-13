use super::*;
use crate::session::checkpoint::reconciliation::{Fact, Field, Id};
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
fn repeated_direct_open_preserves_draft_and_refuses_registration_substitution() {
	let checkpoint = Checkpoint::empty()
		.for_page_directory("directory", None, &Addresses)
		.unwrap();
	let intent = DocumentText::from(
		r#"{"kind":"direct","id":"conversation","directory":"directory","peer":"bob","peerRegistrationId":"00000000-0000-0000-0000-000000000000","closed":false,"draft":""}"#,
	);
	let checkpoint = Command::OpenDirect
		.apply(&checkpoint, core::slice::from_ref(&intent), &Addresses, &())
		.unwrap();
	let checkpoint = Command::SetDraft
		.apply(
			&checkpoint,
			&["conversation".into(), "unsent text".into()],
			&Addresses,
			&(),
		)
		.unwrap();
	let checkpoint = Command::StartDirect
		.apply(&checkpoint, core::slice::from_ref(&intent), &Addresses, &())
		.unwrap();
	let checkpoint = Command::CloseDirect
		.apply(&checkpoint, &["conversation".into()], &Addresses, &())
		.unwrap();
	let checkpoint = Command::OpenDirect
		.apply(&checkpoint, &[intent], &Addresses, &())
		.unwrap();
	assert_eq!(checkpoint.0.conversations.0.len(), 1);
	let Conversation::Direct(direct) = &checkpoint.0.conversations.0[0] else {
		panic!("direct entry")
	};
	assert!(!direct.closed);
	assert_eq!(direct.draft.text().as_str(), Some("unsent text"));
	let substituted = DocumentText::from(
		r#"{"kind":"direct","id":"conversation","directory":"directory","peer":"mallory","peerRegistrationId":"ffffffff-ffff-ffff-ffff-ffffffffffff","closed":false,"draft":""}"#,
	);
	assert!(
		Command::OpenDirect
			.apply(&checkpoint, &[substituted], &Addresses, &())
			.is_err()
	);
}

#[test]
fn registration_retirement_closes_only_the_exact_durable_direct_intent() {
	let checkpoint = Checkpoint::empty()
		.for_page_directory("directory", None, &Addresses)
		.unwrap();
	let intent = DocumentText::from(
		r#"{"kind":"direct","id":"conversation","directory":"directory","peer":"bob","peerRegistrationId":"00000000-0000-0000-0000-000000000000","closed":false,"draft":"unsent"}"#,
	);
	let checkpoint = Command::OpenDirect
		.apply(&checkpoint, &[intent], &Addresses, &())
		.unwrap();
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
