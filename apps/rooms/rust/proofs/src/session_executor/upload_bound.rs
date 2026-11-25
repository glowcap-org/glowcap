//! An upload whose observation expires before its post is acknowledged pauses,
//! and only its source's resume runs it again. After the post nothing pauses
//! it (`upload_fill.rs`).
use super::uploads::{Trace, outcome, request};
use super::*;

/// `targets` are the uploads fixture's: its files resource first and the
/// blob an upload reads third.
pub(super) async fn run(
	host: &Host,
	platform: &Platform,
	root: &Ref,
	source: &Ref,
	targets: &[Ref],
	trace: &Rc<Trace>,
) {
	let [_, _, blob, ..] = targets else {
		panic!("the uploads fixture restores its files resource and a blob");
	};
	let (args, canonical) = request(
		host,
		source,
		blob,
		"bounded-staging",
		rooms_application::content::session::uploads::Kind::Post,
		true,
	)
	.await;
	let before = trace.steps.borrow().len();
	// Only the pipeline's own wait for staging and the post expires, so the
	// job reaches it past every bound before it, and a pipeline with no such
	// bound is not paused.
	platform.only.set(Some("transfer::Step"));
	platform.expired.set(true);
	super::mutate(host, source, "sendFiles", &args).await.unwrap();
	let paused = super::finished(host, root, "bounded-staging", source).await;
	platform.expired.set(false);
	platform.only.set(None);
	assert_eq!(
		platform.expired_waits.get(),
		1,
		"exactly the staging and post observation expired"
	);
	assert_eq!(
		paused.as_str(),
		Some("unknown"),
		"an expired observation before the post pauses the job, so its receipt no longer answers running"
	);
	assert_eq!(
		trace.steps.borrow().len(),
		before,
		"a paused upload has staged and posted nothing"
	);
	assert!(
		super::recovery::inert(host, root)
			.await
			.iter()
			.any(|(id, _)| id == "bounded-staging"),
		"a paused upload changes nothing until its source resumes it"
	);
	let resume = |access: &Ref| {
		host.send(
			access,
			"resume-effect",
			&["bounded-staging".into(), canonical.as_str().into()],
		)
	};
	assert!(
		resume(root).await.is_err(),
		"only the upload's own source can resume it"
	);
	assert_eq!(
		resume(source).await.unwrap().as_str(),
		Some("pending"),
		"the source's resume runs the paused upload again"
	);
	let settled = outcome(host, source, "bounded-staging", &canonical).await;
	assert!(settled.files_complete && settled.line.is_some());
	let released = host
		.send(
			source,
			"release-effect",
			&["bounded-staging".into(), canonical.as_str().into()],
		)
		.await
		.unwrap();
	assert_eq!(
		released.as_str(),
		Some("released"),
		"a settled receipt holds a place until released"
	);
}
