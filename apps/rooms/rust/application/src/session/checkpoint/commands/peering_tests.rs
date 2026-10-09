use super::*;

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
fn leaving_the_selected_directory_selects_a_remaining_room() {
	let mut state = State::empty();
	state.directories = serde_json::from_str(
		r#"[
			{"id":"home","locator":"home","home":true,"nick":"alice","standing":null},
			{"id":"foreign","locator":"foreign","home":false,"nick":"alice","standing":null}
		]"#,
	)
	.unwrap();
	state.conversations = serde_json::from_str(
		r#"[
			{"kind":"room","id":"lobby","directory":"home","name":"lobby","held":false,"standing":null,"draft":""},
			{"kind":"room","id":"elsewhere","directory":"foreign","name":"elsewhere","held":false,"standing":null,"draft":""}
		]"#,
	)
	.unwrap();
	state.active = serde_json::from_str(r#""elsewhere""#).unwrap();

	let left = Command::LeaveDirectory
		.apply(&Checkpoint(state), &["foreign".into()], &Addresses, &())
		.unwrap();

	assert_eq!(left.active().and_then(DocumentText::as_str), Some("lobby"));
}
