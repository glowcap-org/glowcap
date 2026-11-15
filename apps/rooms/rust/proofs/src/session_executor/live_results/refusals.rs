//! A refused callback of a post-commit verb is reported once with its verb and
//! reason. The caller still receives the bare refusal and nothing more. A
//! closing session reports none.
use super::*;
use std::cell::RefCell;

pub(super) type Reports = Rc<RefCell<Vec<(String, String)>>>;

async fn refused(host: &Host, target: &Ref, verb: &str, args: &[Argument], reason: &str) {
	let error = host.send(target, verb, args).await.unwrap_err();
	assert_eq!(error.message(), Some(reason), "{verb} refusal as its caller reads it");
}

pub(super) async fn run(host: &Host, root: &Ref, source: &Ref, reports: &Reports, canonical: &str) {
	let before = reports.borrow().len();
	let arity = [Argument::from("posted")];
	refused(host, source, "effect-result", &arity, "ApplicationRefused").await;
	{
		let reports = reports.borrow();
		assert_eq!(reports.len(), before + 1, "one report for the first refusal");
		let (operation, cause) = &reports[before];
		assert_eq!(operation, "refused effect-result");
		assert!(cause.contains("effect-result takes id and original intent"), "{cause}");
	}
	refused(host, source, "effect-result", &arity, "ApplicationRefused").await;
	assert_eq!(reports.borrow().len(), before + 1, "the same refusal is reported once");
	// A well-formed intent for an effect the session never held passes the
	// requirement and is refused later, when its references are prepared.
	let unknown = [Argument::from("missing"), Argument::from(canonical)];
	refused(host, source, "effect-result", &unknown, "ApplicationRefused").await;
	{
		let reports = reports.borrow();
		assert_eq!(reports.len(), before + 2, "one report for the references refusal");
		let (operation, cause) = &reports[before + 1];
		assert_eq!(operation, "refused effect-result");
		assert!(cause.contains("unknown effect"), "{cause}");
	}
	refused(host, source, "effect-result", &unknown, "ApplicationRefused").await;
	assert_eq!(
		reports.borrow().len(),
		before + 2,
		"the same references refusal is reported once"
	);
	// Outside the post-commit set, a callback refusal is not reported.
	refused(host, source, "effect-reader", &arity, "ApplicationRefused").await;
	assert_eq!(
		reports.borrow().len(),
		before + 2,
		"a verb outside the set reports nothing"
	);
	// An invoke refusal carries its reason to the caller, so it is not reported again.
	refused(
		host,
		root,
		"effect-adopted",
		&arity,
		"original source capability required",
	)
	.await;
	assert_eq!(reports.borrow().len(), before + 2, "an invoke refusal reports nothing");
}

/// A closing session refuses these verbs as an expected part of shutdown, so
/// the reporter hears nothing. The verb and cause here have not been reported
/// before, so silence is not deduplication.
pub(super) async fn closing(host: &Host, source: &Ref, reports: &Reports) {
	let before = reports.borrow().len();
	refused(
		host,
		source,
		"effect-status",
		&[Argument::from("posted")],
		"ApplicationRefused",
	)
	.await;
	assert_eq!(
		reports.borrow().len(),
		before,
		"a closing session reports no refusal: {:?}",
		reports.borrow()
	);
}
