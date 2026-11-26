//! A source reads back the intent of its own receipt with the rights its
//! effect needs and no more, so it can give the receipt up. Every other
//! access, whatever rights it holds, learns no intent through the verb.
use super::*;
use crate::session_executor::connection_results::edit_policy;

/// The accesses `effect-intent` is asked through, beside the source.
pub(super) struct Askers<'a> {
	/// The source's own control, which narrows its rights.
	pub control: &'a Ref,
	/// A sibling with the source's own collaborator rights.
	pub sibling: &'a Ref,
	/// An access that may only observe.
	pub observer: &'a Ref,
}

pub(super) async fn run(
	host: &Host,
	owner: &managed::Session<Platform>,
	policy: &loam::Policy,
	source: &Ref,
	terms: loam::PolicyValue,
	askers: Askers<'_>,
	(operation, canonical): (&str, &str),
) {
	let intent = |from: &Ref, operation: &str| {
		let from = from.clone();
		let operation = operation.to_owned();
		async move { host.send(&from, "effect-intent", &[operation.into()]).await }
	};
	assert_eq!(
		intent(source, operation).await.unwrap(),
		Argument::String(canonical.into()),
		"a collaborator reads back the intent of its own receipt"
	);
	let everything: Vec<_> = session::SUPPORTED.iter().map(|p| p.key()).collect();
	let administrator = policy.value_for_kind(session::KIND, &everything, &[]).unwrap();
	let (administrator, _) = owner
		.derive(administrator, 1, full_control(administrator))
		.await
		.unwrap();
	for (asker, who) in [
		(askers.sibling, "a sibling with equal rights"),
		(askers.observer, "an observer"),
		(&administrator, "an administrator that is not the source"),
	] {
		assert!(
			intent(asker, operation).await.is_err(),
			"{who} learns no intent of another source's receipt"
		);
	}
	assert_eq!(
		intent(askers.observer, "never-sent").await.unwrap(),
		Argument::Void,
		"an absent receipt answers void to any access, as effect-holder answers nobody"
	);
	let narrowed = policy
		.value_for_kind(session::KIND, &[Permission::ObserveWorkspace.key()], &[])
		.unwrap();
	edit_policy(host, askers.control, narrowed).await;
	assert!(
		intent(source, operation).await.is_err(),
		"a source narrowed below its effect's rights is refused, as release-effect refuses it"
	);
	edit_policy(host, askers.control, terms).await;
	assert_eq!(
		intent(source, operation).await.unwrap(),
		Argument::String(canonical.into())
	);
}
