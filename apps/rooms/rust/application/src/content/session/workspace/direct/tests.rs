//! The direct plan on its own: append under the operation, reopen the last
//! closed row of a registration in place, give a route back while a row is
//! open under any contact the directory held, and refuse a directory whose
//! contact moved between the command and its acquisition. The runtime proofs
//! hold the session's participation rule to the same plan.
use super::*;
use crate::content::session::workspace::InvalidIntent;
use alloc::string::ToString;
use serde_json::{Value, json};

fn key(slot: u64) -> String {
	alloc::format!("{slot:016x}{:016x}", 1)
}
fn typed<K>(slot: u64) -> custody::FieldKey<K> {
	custody::FieldKey::new(core::num::NonZeroU64::new(slot).unwrap(), core::num::NonZeroU64::MIN)
}
fn directory(inbox: u64) -> Value {
	json!({"id":"d","access":key(1),"name":key(2),"source":key(3),"inbox":key(inbox),"home":true,
		"nick":"bot","nickAllocation":"exact","standing":null})
}
fn direct(id: &str, registration: &str, closed: bool, draft: &str) -> Value {
	json!({"kind":"direct","id":id,"directory":"d","peer":"Ann","access":(if closed { Value::Null } else { key(9).into() }),
		"introduction":{"access":key(1),"name":key(2),"callback":key(4),"registration":registration,"opening":"o"},
		"closed":closed,"draft":draft})
}
fn intent(directory: Value, rows: Value) -> Intent {
	Intent::decode(
		&json!({"version":1,"directories":[directory],"conversations":rows,"invitations":[],"active":null,
			"standing":"","ignored":[],"keepHistory":false,"connection":"fastest",
			"archive":null,"archiveControl":null,"operators":[],"peering":[]})
		.to_string(),
	)
	.unwrap()
}
fn start(registration: &str) -> StartDirect<'_> {
	StartDirect {
		directory: "d",
		peer: "ann",
		registration,
		opening: "opening",
	}
}
fn plan(workspace: &Intent, registration: &str) -> Result<DirectAdoption, DirectRefusal> {
	let receipt = results::Direct { inbox: typed(20) };
	adopt_direct(
		workspace,
		workspace,
		"operation",
		&start(registration),
		&receipt,
		typed(30),
		typed(40),
	)
}
fn row(plan: &DirectAdoption, at: usize) -> &Direct {
	match &plan.intent.conversations.as_slice()[at] {
		Conversation::Direct(row) => row,
		Conversation::Room(_) => panic!("a room at {at}"),
	}
}

#[test]
fn a_new_peer_gets_a_row_named_by_the_operation_that_holds_the_route() {
	let workspace = intent(directory(4), json!([]));
	let plan = plan(&workspace, "r1").unwrap();
	assert_eq!(plan.conversation.text().as_str(), Some("operation"));
	let opened = row(&plan, 0);
	assert_eq!(
		(opened.closed, opened.inbox, opened.access, opened.source),
		(false, None, Some(typed(30)), Some(typed(40)))
	);
	assert_eq!(opened.peer.text().as_str(), Some("ann"));
	let introduction = opened.introduction.as_ref().unwrap();
	assert_eq!(introduction.callback, typed(4));
	assert_eq!(introduction.opening.text().as_str(), Some("opening"));
	let role = custody::Role::DirectAccess;
	assert_eq!(
		plan.mappings,
		[[
			custody::Coordinate::new(role, typed::<custody::DirectAccess>(20)),
			custody::Coordinate::new(role, typed::<custody::DirectAccess>(30)),
		]]
	);
}

#[test]
fn the_last_closed_row_of_the_same_registration_reopens_in_place_with_its_draft() {
	let workspace = intent(
		directory(4),
		json!([
			direct("old", "r1", true, "first"),
			direct("other", "r2", true, ""),
			direct("last", "r1", true, "kept")
		]),
	);
	let plan = plan(&workspace, "r1").unwrap();
	assert_eq!(plan.conversation.text().as_str(), Some("last"));
	assert_eq!(plan.intent.conversations.as_slice().len(), 3);
	let reopened = row(&plan, 2);
	assert!(!reopened.closed);
	assert_eq!(reopened.draft.text().as_str(), Some("kept"));
	assert!(row(&plan, 0).closed && row(&plan, 1).closed);
}

#[test]
fn a_closed_row_under_another_registration_stays_closed_and_a_new_row_opens() {
	let workspace = intent(directory(4), json!([direct("old", "r1", true, "")]));
	let plan = plan(&workspace, "r2").unwrap();
	assert_eq!(plan.conversation.text().as_str(), Some("operation"));
	assert!(row(&plan, 0).closed);
	assert!(!row(&plan, 1).closed);
}

#[test]
fn an_open_row_is_found_by_registration_under_any_contact_its_directory_held() {
	let workspace = intent(
		directory(4),
		json!([direct("closed", "r1", true, ""), direct("open", "r1", false, "")]),
	);
	let found = open_direct(&workspace, "d", "r1").unwrap();
	assert_eq!(found.id.text().as_str(), Some("open"));
	assert!(open_direct(&workspace, "d", "r2").is_none());
	assert!(open_direct(&workspace, "elsewhere", "r1").is_none());
	assert_eq!(reopened_direct(&workspace, "d", "r1").map(|(at, _)| at), Some(0));
	// The directory registered again, under a new inbox. The row keeps its own
	// route and inbox, so it still reaches the member.
	let moved = intent(directory(5), json!([direct("open", "r1", false, "")]));
	assert_eq!(open_direct(&moved, "d", "r1").unwrap().id.text().as_str(), Some("open"));
}

#[test]
fn after_the_directory_registers_again_its_open_row_is_reused_and_a_new_route_is_given_back() {
	// The sequence a `--dm` or a page open meets: a row introduced under the
	// directory's first contact is open, the directory's contact changes, and
	// the member is reached again. Every caller finds the open row first, and
	// a route introduced under the new contact is given back to it.
	let rows = json!([direct("open", "r1", false, "kept")]);
	let before = intent(directory(4), rows.clone());
	let after = intent(directory(5), rows);
	let open = Id::new("open".into()).unwrap();
	assert_eq!(open_direct(&before, "d", "r1").map(|row| &row.id), Some(&open));
	assert_eq!(open_direct(&after, "d", "r1").map(|row| &row.id), Some(&open));
	assert_eq!(plan(&after, "r1"), Err(DirectRefusal::Open(open)));
}

#[test]
fn a_directory_whose_contact_moved_or_left_refuses_without_a_plan() {
	let receipt = results::Direct { inbox: typed(20) };
	let before = intent(directory(4), json!([]));
	let moved = intent(directory(5), json!([]));
	let adopt = |original: &Intent, current: &Intent| {
		adopt_direct(
			original,
			current,
			"operation",
			&start("r1"),
			&receipt,
			typed(30),
			typed(40),
		)
	};
	assert_eq!(adopt(&before, &moved), Err(DirectRefusal::Changed));
	let mut gone = before.clone();
	gone.directories = List::default();
	assert_eq!(adopt(&before, &gone), Err(DirectRefusal::Removed));
	assert_eq!(adopt(&gone, &before), Err(DirectRefusal::Unknown));
	let mut unregistered = directory(4);
	unregistered["inbox"] = Value::Null;
	let unregistered = intent(unregistered, json!([]));
	assert_eq!(adopt(&unregistered, &unregistered), Err(DirectRefusal::Unregistered));
}

#[test]
fn start_direct_reads_exactly_four_arguments_and_writes_them_back() {
	let args = ["d", "ann", "r1", "o"].map(String::from);
	let read = StartDirect::read(&args).unwrap();
	assert_eq!(read.arguments(), args);
	assert!(StartDirect::read(&args[..3]).is_none());
}

#[test]
fn a_route_for_a_registration_with_an_open_row_is_given_back_whoever_opened_it() {
	// This session opened `ours`: it holds the member's route. The member
	// opened `theirs`: the session accepted their introduction and holds no
	// route yet, and the opening is the member's. Either one takes the route.
	let ours = direct("ours", "r1", false, "");
	let mut theirs = direct("theirs", "r1", false, "");
	theirs["access"] = Value::Null;
	theirs["source"] = key(3).into();
	theirs["introduction"]["opening"] = "the member's opening".into();
	for (open, inbox) in [(&ours, 4), (&theirs, 4), (&ours, 5), (&theirs, 5)] {
		let workspace = intent(directory(inbox), json!([direct("closed", "r1", true, ""), open]));
		let id = open["id"].as_str().unwrap();
		let refused = plan(&workspace, "r1").unwrap_err();
		assert_eq!(
			refused,
			DirectRefusal::Open(Id::new(id.into()).unwrap()),
			"{id} {inbox}"
		);
	}
	let other = intent(directory(4), json!([direct("open", "r2", false, "")]));
	assert_eq!(
		plan(&other, "r1").unwrap().conversation.text().as_str(),
		Some("operation")
	);
}

#[test]
fn a_replacement_opens_no_second_row_for_a_registration() {
	let closed = direct("closed", "r1", true, "");
	let open = direct("open", "r1", false, "");
	let mut reopened = closed.clone();
	reopened["closed"] = false.into();
	let mut current = intent(directory(4), json!([closed.clone(), open.clone()]));
	// Reopening the closed row, or adding another, would give `r1` two.
	for rows in [
		json!([reopened.clone(), open.clone()]),
		json!([closed.clone(), open.clone(), direct("new", "r1", false, "")]),
	] {
		assert_eq!(
			current.replace_configuration(intent(directory(4), rows)),
			Err(InvalidIntent::DirectOpen)
		);
	}
	// Another registration, or closing the open row first, is one open row each.
	let mut other = direct("other", "r2", false, "");
	other["access"] = key(10).into();
	current
		.replace_configuration(intent(directory(4), json!([closed.clone(), open.clone(), other])))
		.unwrap();
	let mut closing = open.clone();
	closing["closed"] = true.into();
	closing["access"] = Value::Null;
	let mut current = intent(directory(4), json!([closed, open.clone()]));
	current
		.replace_configuration(intent(directory(4), json!([reopened.clone(), closing])))
		.unwrap();
	// Two rows the receiving side already holds open stay as they are.
	let mut theirs = open.clone();
	theirs["id"] = "theirs".into();
	theirs["access"] = Value::Null;
	let mut both = intent(directory(4), json!([open.clone(), theirs.clone()]));
	both.replace_configuration(intent(directory(4), json!([open, theirs])))
		.unwrap();
}
