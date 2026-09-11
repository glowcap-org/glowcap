use super::*;
use crate::{
	fields::{Nullable, SafeInteger},
	grants::Access,
	session::{
		checkpoint::{
			commands::{Command, CommandRoutes},
			Checkpoint, Routes,
		},
		snapshot::views::Adoption,
	},
};
use alloc::rc::Rc;
struct Addresses;
impl Routes for Addresses {
	fn locator_authority(&self, value: &str) -> Option<String> {
		Some(value.into())
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
fn snapshot() -> Snapshot {
	Snapshot {
		revision: SafeInteger::new(0).unwrap(),
		checkpoint: Rc::new(
			Checkpoint::empty()
				.for_page_directory("directory", None, &Addresses)
				.unwrap(),
		),
		pending_effects: crate::fields::List::new(Vec::new()).unwrap(),
		issues: crate::fields::List::new(Vec::new()).unwrap(),
		connected_directories: crate::fields::List::new(Vec::new()).unwrap(),
		pending_effect_details: crate::fields::List::new(Vec::new()).unwrap(),
		member_locator: Nullable::Null,
		room_views: crate::fields::List::new(Vec::new()).unwrap(),
		archive_shares: crate::fields::List::new(Vec::new()).unwrap(),
		directory_views: crate::fields::List::new(Vec::new()).unwrap(),
		access: Access::Admin,
		workspace_adoption: Adoption::Available,
		grants: crate::fields::List::new(Vec::new()).unwrap(),
		suspended_note: None,
		handed_rooms: crate::fields::List::new(Vec::new()).unwrap(),
	}
}
fn credential(snapshot: &mut Snapshot, secret: &str) {
	let raw = alloc::format!(r#"[{{"capability":"operator","scope":"directory","swiss":"{secret}"}}]"#);
	snapshot.checkpoint = Rc::new(
		Command::ReplaceOperationsCapabilities
			.apply(&snapshot.checkpoint, &[raw.into()], &Addresses, &())
			.unwrap(),
	);
}
#[test]
fn refreshes_coalesce_and_only_the_latest_filter_can_publish() {
	let mut state = Operations::default();
	let kind = Kind::parse("operator").unwrap();
	state.request(kind, None).unwrap();
	let old = state.begin(kind).unwrap();
	for _ in 0..1000 {
		state.request(kind, None).unwrap();
	}
	state
		.request(
			kind,
			Some(Filter {
				search: "latest".into(),
				reference: None,
			}),
		)
		.unwrap();
	assert!(state.begin(kind).is_none());
	assert!(!state.finish(&old));
	let latest = state.begin(kind).unwrap();
	assert_eq!(latest.filter.search, "latest");
	assert!(state.finish(&latest));
	assert!(state.begin(kind).is_none());
}
#[test]
fn continuous_invalidations_publish_progress_without_waiting_for_quiet() {
	let mut snapshot = snapshot();
	credential(&mut snapshot, "held");
	let mut state = Operations::default();
	let kind = Kind::parse("operator").unwrap();
	state.observe(&snapshot).unwrap();
	for _ in 0..100 {
		let read = state.begin(kind).unwrap();
		state.invalidate("directory").unwrap();
		assert!(state.begin(kind).is_none());
		assert!(
			state.finish(&read),
			"a newer invalidation must not starve a valid answer"
		);
		assert!(state.pending(kind).unwrap() > read.version);
	}
	let final_read = state.begin(kind).unwrap();
	assert!(state.finish(&final_read));
	assert!(state.pending(kind).is_none());
}
#[test]
fn invalidation_still_retires_an_outstanding_page_cursor() {
	let mut snapshot = snapshot();
	credential(&mut snapshot, "held");
	let mut state = Operations::default();
	let kind = Kind::parse("operator").unwrap();
	state.observe(&snapshot).unwrap();
	// Supply the already-admitted page slot; its cursor must not survive an
	// invalidation even though a whole snapshot from this epoch may publish.
	state.slots[kind.index()].page = Some((Category::Rooms, 32));
	let page = state.begin(kind).unwrap();
	state.invalidate("directory").unwrap();
	assert!(!state.finish(&page));
	let refreshed = state.begin(kind).unwrap();
	assert!(refreshed.page.is_none());
	assert!(state.finish(&refreshed));
}
#[test]
fn credential_replacement_and_removal_retire_outstanding_answers() {
	let mut snapshot = snapshot();
	credential(&mut snapshot, "old");
	let mut state = Operations::default();
	let kind = Kind::parse("operator").unwrap();
	assert!(state.observe(&snapshot).unwrap()[kind.index()]);
	let old = state.begin(kind).unwrap();
	credential(&mut snapshot, "new");
	assert!(state.observe(&snapshot).unwrap()[kind.index()]);
	assert!(!state.finish(&old));
	let current = state.begin(kind).unwrap();
	snapshot.access = Access::None;
	assert!(state.observe(&snapshot).unwrap()[kind.index()]);
	assert!(state.scope(kind).is_none());
	assert!(!state.finish(&current));
	let clear = state.begin(kind).unwrap();
	assert!(clear.scope.is_none());
	assert!(state.finish(&clear));
}

#[test]
fn queued_action_keeps_its_credential_across_revision_retry() {
	let mut snapshot = snapshot();
	credential(&mut snapshot, "original");
	let kind = Kind::parse("operator").unwrap();
	let target = Target::select(&snapshot, kind).unwrap();
	snapshot.revision = SafeInteger::new(1).unwrap();
	assert!(target.check(&snapshot).is_ok());
	credential(&mut snapshot, "replacement");
	assert!(target.check(&snapshot).is_err());
	let replacement = Target::select(&snapshot, kind).unwrap();
	snapshot.access = Access::None;
	assert!(replacement.check(&snapshot).is_err());
	assert!(Target::select(&snapshot, kind).is_err());
}
