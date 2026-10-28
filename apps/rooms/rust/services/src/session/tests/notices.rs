//! The operator hears each membership failure once while it stands.
use super::*;
use notice::StandingFailures;
use rooms_runtime::session::managed::MembershipTarget;
use std::{cell::RefCell, rc::Rc};

#[test]
fn a_standing_failure_is_told_once() {
	let told = Rc::new(RefCell::new(Vec::new()));
	let report: Report = {
		let told = told.clone();
		Rc::new(move |notice| told.borrow_mut().push(notice.to_string()))
	};
	let directory = MembershipTarget::Directory("ocapn://directory".into());
	let room = MembershipTarget::Room("room".into());
	let gone = glowcap::loam::refusal("gone");
	let mut standing = StandingFailures::default();
	standing.report(&[(directory.clone(), gone.clone())], &report);
	standing.report(&[(directory.clone(), gone.clone())], &report);
	assert_eq!(told.borrow().len(), 1, "a failure that still stands is not told again");
	standing.report(
		&[(directory.clone(), gone.clone()), (room.clone(), gone.clone())],
		&report,
	);
	assert_eq!(told.borrow().len(), 2, "a new failure beside a standing one is told");
	standing.report(&[(room.clone(), glowcap::loam::refusal("refused"))], &report);
	assert_eq!(told.borrow().len(), 3, "a changed cause is told");
	standing.report(&[], &report);
	standing.report(&[(directory, gone)], &report);
	assert_eq!(
		told.borrow().len(),
		4,
		"a failure that cleared and returned is told again"
	);
}
