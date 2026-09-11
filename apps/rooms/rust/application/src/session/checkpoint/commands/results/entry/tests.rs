use super::*;
struct Addresses;
impl Routes for Addresses {
	fn locator_authority(&self, _: &str) -> Option<String> {
		Some("directory".into())
	}
	fn sturdyref_authority(&self, _: &str) -> Option<String> {
		Some("directory".into())
	}
}
impl CommandRoutes for Addresses {
	fn authority_token(&self, _: &str) -> Option<String> {
		Some("publication".into())
	}
}

#[test]
fn resolved_membership_preserves_draft_and_refuses_replaced_authority() {
	let current = Checkpoint::empty()
		.for_page_directory("directory", None, &Addresses)
		.unwrap();
	let current = super::super::super::Command::SetDirectoryNick
		.apply(&current, &["directory".into(), "alice".into()], &Addresses, &())
		.unwrap();
	let raw = DocumentText::from(
		r#"{"locator":"directory","nick":"alice","conversation":{"kind":"room","id":"held","directory":"directory","name":"plans","held":true,"link":"ocapn://directory/s/first","standing":null,"draft":"unsent"}}"#,
	);
	let current = super::super::super::Command::JoinRoom
		.apply(&current, core::slice::from_ref(&raw), &Addresses, &())
		.unwrap();
	let mut intent: Intent = json(&raw, MAX_JSON).unwrap();
	intent.conversation.id = text(&"new-gesture".into()).unwrap();
	intent.conversation.link = Some(text(&"ocapn://directory/s/alias".into()).unwrap());
	let result = returned(&current, Some("held"), "plans").unwrap();
	let selected = apply(&current, &intent, &result.clone().into(), &Addresses).unwrap();
	assert_eq!(selected.0.conversations.0.len(), 1);
	assert_eq!(selected.active().and_then(DocumentText::as_str), Some("held"));
	assert_eq!(
		named_room(&selected.0, &"held".into()).unwrap().draft.text().as_str(),
		Some("unsent")
	);
	let mut changed = selected.0.clone();
	let Conversation::Room(room) = &mut changed.conversations.0[0] else {
		panic!("room")
	};
	room.link = Some(text(&"ocapn://directory/s/replacement".into()).unwrap());
	assert!(apply(&Checkpoint(changed), &intent, &result.into(), &Addresses).is_err());
}
