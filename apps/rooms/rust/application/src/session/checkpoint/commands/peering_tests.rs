use super::*;
use alloc::string::ToString;
use serde_json::json;

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
fn bundle_replacement_uses_current_home_and_preserves_foreign_credentials() {
	let mut state = State::empty();
	state.directories = serde_json::from_str(
		&json!([
			{"id":"first", "locator":"first", "home":false, "nick":"ada", "standing":null},
			{"id":"second", "locator":"second", "home":true, "nick":"ada", "standing":null}
		])
		.to_string(),
	)
	.unwrap();
	state.capabilities.operations = serde_json::from_str(
		&json!([
			{"capability":"listeners", "scope":"first", "swiss":"foreign"},
			{"capability":"diagnostics", "scope":"second", "swiss":"old"},
			{"capability":"viz", "scope":"ws://old.test/viz", "swiss":"old-viz"}
		])
		.to_string(),
	)
	.unwrap();
	let before = Checkpoint(state);
	let next = Command::ReplaceOperationsBundle
		.apply(
			&before,
			&[
				"ROOMS-OPERATOR operator-swiss\nROOMS-VIZ viz-swiss".into(),
				"ws://advertised.test/viz".into(),
				before.operations_bundle_context().into(),
			],
			&Addresses,
			&(),
		)
		.unwrap();
	let credentials: alloc::vec::Vec<_> = next.operations().map(|c| (c.capability, c.scope, c.swiss)).collect();
	assert_eq!(
		credentials,
		[
			("listeners", "first", "foreign"),
			("operator", "second", "operator-swiss"),
			("viz", "ws://old.test/viz", "viz-swiss"),
		]
	);
	assert_eq!(
		next.operations_bundle(),
		"ROOMS-OPERATOR operator-swiss\nROOMS-VIZ viz-swiss"
	);
	let cleared = Command::ReplaceOperationsBundle
		.apply(
			&next,
			&["".into(), "".into(), next.operations_bundle_context().into()],
			&Addresses,
			&(),
		)
		.unwrap();
	assert_eq!(cleared.operations().count(), 1);
	assert_eq!(cleared.operations().next().unwrap().swiss, "foreign");
	let restored = Command::ReplaceOperationsBundle
		.apply(
			&cleared,
			&[
				"ROOMS-VIZ fresh".into(),
				"ws://advertised.test/viz".into(),
				cleared.operations_bundle_context().into(),
			],
			&Addresses,
			&(),
		)
		.unwrap();
	assert_eq!(
		restored.operations().find(|c| c.capability == "viz").unwrap().scope,
		"ws://advertised.test/viz"
	);
	assert!(Command::ReplaceOperationsBundle
		.apply(
			&before,
			&["ROOMS-OPERATOR ocapn://other.tcp/s/secret".into(), "".into(),],
			&Addresses,
			&()
		)
		.is_err());
	assert_eq!(
		before
			.operations()
			.find(|c| c.capability == "diagnostics")
			.unwrap()
			.swiss,
		"old"
	);
}

#[test]
fn bundle_edit_cannot_retarget_authority_after_scope_changes() {
	let before = Checkpoint::empty()
		.for_page_directory("first", None, &Addresses)
		.unwrap();
	let context = before.operations_bundle_context();
	let changed = before.for_page_directory("second", None, &Addresses).unwrap();
	assert!(matches!(
		Command::ReplaceOperationsBundle.apply(
			&changed,
			&["ROOMS-OPERATOR secret-for-first".into(), "".into(), context.into(),],
			&Addresses,
			&()
		),
		Err(Error::OperationsScope)
	));
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
