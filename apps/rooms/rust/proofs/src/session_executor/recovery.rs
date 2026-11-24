//! Recovery uses actual source custody, including after a physical Store reopen.
use super::*;
use rooms_glowcap::client::{
	access::Control,
	workspace::{EffectStatus, Release, Workspace},
};

/// The operations the session names as receipts that can no longer change,
/// each with the source that sent it, as its revoked receipt owner reads them.
pub(super) async fn inert(host: &Host, root: &Ref) -> Vec<(String, Ref)> {
	host.send(root, "inert-effects", &[root.clone().into()])
		.await
		.unwrap()
		.as_list()
		.unwrap()
		.iter()
		.map(|row| {
			let Some([Argument::String(id), source]) = row.as_list() else {
				panic!("an inert receipt row names an operation and its source");
			};
			(id.clone(), Ref::try_from(source).unwrap())
		})
		.collect()
}

pub(super) async fn resume(host: &Host, root: &Ref, source: &Ref, sibling: &Ref, canonical: &str) {
	let workspace = Workspace::local(host.clone(), Platform::default(), source.clone());
	let other = Workspace::local(host.clone(), Platform::default(), sibling.clone());
	let rows = workspace.effects().await.unwrap();
	assert_eq!(rows.len(), 1);
	assert_eq!(rows[0].operation, "effect-one");
	assert_eq!(rows[0].status, EffectStatus::Unknown);
	assert!(rows[0].resumable);
	assert!(
		other.effects().await.unwrap().is_empty(),
		"equal policy does not disclose a sibling's receipts"
	);
	assert!(other.recover_effect("effect-one").await.is_err());
	assert!(
		host.send(source, "resume-effect", &["effect-one".into(), "[]".into()])
			.await
			.is_err()
	);
	let recovered = workspace
		.recover_effect("effect-one")
		.await
		.unwrap()
		.expect("unresolved receipt");
	assert_eq!(
		host.send(source, "effect-intent", &["effect-one".into()])
			.await
			.unwrap()
			.as_str(),
		Some(canonical)
	);
	assert_eq!(recovered.status().await.unwrap(), EffectStatus::Unknown);
	assert!(
		inert(host, root).await.iter().any(|(id, _)| id == "effect-one"),
		"a paused executor changes nothing unless its source resumes it, so its receipt is inert"
	);
	assert_eq!(recovered.resume().await.unwrap(), EffectStatus::Pending);
	assert_eq!(
		recovered.resume().await.unwrap(),
		EffectStatus::Pending,
		"resume never installs a duplicate executor"
	);
	assert!(
		host.send(sibling, "release-effect", &["effect-one".into(), canonical.into()])
			.await
			.is_err(),
		"equal policy cannot release a sibling's receipt"
	);
	assert_eq!(
		recovered.release().await.unwrap(),
		Release::Running,
		"a receipt whose executor is running is not released"
	);
	assert_eq!(recovered.status().await.unwrap(), EffectStatus::Pending);
	assert!(
		inert(host, root).await.iter().all(|(id, _)| id != "effect-one"),
		"a receipt whose executor lives can still settle, so it is not inert"
	);
	assert_eq!(
		host.send(
			root,
			"release-inert-effect",
			&[root.clone().into(), "effect-one".into(), source.clone().into()],
		)
		.await
		.unwrap(),
		Argument::String("running".into()),
		"an inert release that meets a running executor keeps the receipt and answers running"
	);
	assert_eq!(recovered.status().await.unwrap(), EffectStatus::Pending);
}

/// The source's release of a receipt whose executor is paused retires that
/// executor and settles the receipt as given up, and nothing brings the
/// executor back.
pub(super) async fn forfeit(host: &Host, source: &Ref, operation: &str, intent: &str) {
	let ask = |verb: &'static str| host.send(source, verb, &[operation.into(), intent.into()]);
	let before = revision(host, source).await;
	assert_eq!(
		ask("release-effect").await.unwrap(),
		Argument::String("released".into()),
		"the source's release retires the paused executor and settles its receipt"
	);
	let released = revision(host, source).await;
	assert!(
		released > before,
		"the release wrote its receipt: {before} -> {released}"
	);
	assert!(
		ask("resume-effect").await.is_err(),
		"a released receipt has no executor left to resume"
	);
	given_up(host, source, operation).await;
	assert_eq!(
		ask("release-effect").await.unwrap(),
		Argument::String("released".into()),
		"a second release changes nothing and answers released"
	);
	assert_eq!(
		revision(host, source).await,
		released,
		"a second release writes nothing"
	);
	given_up(host, source, operation).await;
}
/// The operations of `source`'s own receipts that still keep a place, sorted,
/// as `held-effects` answers them to `source`.
pub(super) async fn held_effects(host: &Host, source: &Ref) -> Vec<String> {
	let Argument::List(rows) = host.send(source, "held-effects", &[]).await.unwrap() else {
		panic!("held effects answer a list");
	};
	let mut held: Vec<_> = rows
		.into_iter()
		.map(|row| match row {
			Argument::String(operation) => operation,
			other => panic!("a held effect is an operation: {other:?}"),
		})
		.collect();
	held.sort_unstable();
	held
}
/// The session's content revision, which every write of its record advances.
pub(super) async fn revision(host: &Host, source: &Ref) -> i64 {
	host.send(source, "snapshot", &[]).await.unwrap().as_list().unwrap()[0]
		.as_i64()
		.unwrap()
}
/// The receipt of `operation` is held, settled as given up: it is still its
/// source's, its outcome is unknown for good, nothing is left to recover, and
/// it holds no place a revoked source's sweep would release.
pub(super) async fn given_up(host: &Host, source: &Ref, operation: &str) {
	assert_eq!(
		host.send(source, "effect-holder", &[operation.into()]).await.unwrap(),
		Argument::String("mine".into()),
		"a released receipt still answers for its source"
	);
	assert_eq!(
		host.send(
			source,
			"effect-status",
			&[operation.into(), Argument::Reference(source.clone())]
		)
		.await
		.unwrap(),
		Argument::String("unknown".into()),
		"a released receipt's outcome is unknown for good"
	);
	assert_eq!(
		host.send(source, "effect-intent", &[operation.into()]).await.unwrap(),
		Argument::Void,
		"a released receipt has nothing to recover"
	);
}

/// Whose receipt an operation is answers the bare fact to any attached source:
/// the source that sent it, one that did not, and one holding no permission at
/// all. The reply names no source and no other receipt.
pub(super) async fn holder(
	host: &Host,
	source: &Ref,
	sibling: &Ref,
	bare: &Ref,
	paused: &(Ref, Ref),
	revoked: &(Ref, Ref),
) {
	let ask = |from: &Ref, operation: &'static str| {
		let from = from.clone();
		async move { host.send(&from, "effect-holder", &[operation.into()]).await.unwrap() }
	};
	assert_eq!(ask(source, "effect-one").await, Argument::String("mine".into()));
	assert_eq!(ask(sibling, "effect-one").await, Argument::String("another".into()));
	assert_eq!(
		ask(bare, "effect-one").await,
		Argument::String("another".into()),
		"an access holding no permission is answered, and learns only that another access sent it"
	);
	assert_eq!(ask(bare, "effect-never-sent").await, Argument::String("nobody".into()));
	assert_eq!(
		held_effects(host, source).await,
		["effect-one"],
		"an unresolved receipt keeps its place, listed for the source that sent it"
	);
	for asker in [sibling, bare] {
		assert_eq!(
			held_effects(host, asker).await,
			Vec::<String>::new(),
			"another source's receipt is never listed, even to one holding no permission"
		);
	}
	assert!(
		host.send(bare, "held-effects", &["effect-one".into()]).await.is_err(),
		"the verb takes no arguments"
	);
	assert!(
		host.send(bare, "effect-holder", &[]).await.is_err(),
		"the verb takes exactly one operation"
	);
	let paused_control = Control::local(host.clone(), Platform::default(), paused.1.clone());
	paused_control
		.pause(management::revision(&paused_control).await)
		.await
		.unwrap();
	assert!(
		host.send(&paused.0, "effect-holder", &["effect-one".into()])
			.await
			.is_err(),
		"a paused asker is refused, as for any read, and learns nothing"
	);
	paused_control
		.resume(management::revision(&paused_control).await)
		.await
		.unwrap();
	assert_eq!(
		ask(&paused.0, "effect-one").await,
		Argument::String("another".into()),
		"a resumed asker is answered"
	);
	let revoked_control = Control::local(host.clone(), Platform::default(), revoked.1.clone());
	revoked_control
		.revoke(management::revision(&revoked_control).await)
		.await
		.unwrap();
	assert!(
		host.send(&revoked.0, "effect-holder", &["effect-one".into()])
			.await
			.is_err(),
		"a revoked asker is refused for good"
	);
}
pub(super) async fn cold(host: &Host, source: &Ref, result: &str, calls: &Cell<usize>, departed: bool) {
	// The session restarted, so no job table holds an executor for any of its
	// receipts, and none of them can change.
	let workspace = Workspace::local(host.clone(), Platform::default(), source.clone());
	let rows = workspace.effects().await.unwrap();
	let mut operations = rows.iter().map(|row| row.operation.as_str()).collect::<Vec<_>>();
	operations.sort_unstable();
	let mut expected = vec![
		"effect-cold",
		"effect-forfeit",
		"effect-late",
		"effect-root",
		"effect-stalled",
		"effect-unconfirmed",
	];
	if departed {
		expected.insert(0, "departure");
	}
	assert_eq!(
		operations, expected,
		"cold inventory contains exactly the root's receipts"
	);
	assert!(rows.iter().all(|row| !row.resumable));
	// No executor survives the restart, so the receipts that keep a place are
	// exactly the ones a revoked source's sweep would find held.
	let mut held_now = workspace.held_effects().await.unwrap();
	held_now.sort_unstable();
	let mut swept: Vec<_> = inert(host, source).await.into_iter().map(|(id, _)| id).collect();
	swept.sort_unstable();
	assert_eq!(held_now, swept, "the held list is the eviction rule's own");
	assert!(
		held_now.iter().any(|held| held == "effect-stalled"),
		"an unresolved receipt keeps its place across the restart: {held_now:?}"
	);
	for id in ["effect-cold", "effect-forfeit", "effect-late", "effect-unconfirmed"] {
		assert!(
			!held_now.iter().any(|held| held == id),
			"a released or settled receipt keeps no place: {held_now:?}"
		);
	}
	let committed = workspace
		.recover_effect("effect-root")
		.await
		.unwrap()
		.expect("unadopted receipt");
	assert_eq!(committed.status().await.unwrap(), EffectStatus::Committed);
	assert_eq!(committed.result().await.unwrap().as_str(), Some(result));
	assert_eq!(committed.resume().await.unwrap(), EffectStatus::Committed);
	let unknown = workspace
		.recover_effect("effect-cold")
		.await
		.unwrap()
		.expect("unresolved receipt");
	assert_eq!(unknown.status().await.unwrap(), EffectStatus::Unknown);
	assert!(
		unknown.resume().await.is_err(),
		"no live observer survives cold opening"
	);
	assert_eq!(unknown.status().await.unwrap(), EffectStatus::Unknown);
	assert!(
		host.send(source, "release-effect", &["effect-cold".into(), "[]".into()])
			.await
			.is_err(),
		"release requires the original intent"
	);
	// Receipts released before the restart are stored as released.
	for id in ["effect-forfeit", "effect-late", "effect-unconfirmed"] {
		given_up(host, source, id).await;
	}
	let held = inert(host, source).await;
	assert!(
		held.iter().all(
			|(id, _)| !["effect-forfeit", "effect-late", "effect-unconfirmed", "effect-cold"].contains(&id.as_str())
		),
		"a released or settled receipt holds no place after a restart"
	);
	assert!(
		held.iter().any(|(held, _)| held == "effect-stalled"),
		"an unresolved receipt holds its place with no executor after a restart, so it can no longer change"
	);
	let (_, sent_by) = held.iter().find(|(id, _)| id == "effect-stalled").unwrap();
	let before = revision(host, source).await;
	let released = host
		.send(
			source,
			"release-inert-effect",
			&[source.clone().into(), "effect-stalled".into(), sent_by.clone().into()],
		)
		.await
		.expect("an unresolved receipt with no executor is released without its access");
	assert_eq!(released, Argument::String("released".into()));
	let swept = revision(host, source).await;
	assert!(
		swept > before,
		"the sweep's release wrote its receipt: {before} -> {swept}"
	);
	assert!(
		inert(host, source).await.iter().all(|(id, _)| id != "effect-stalled"),
		"a released receipt holds no place, so it is no longer listed"
	);
	assert!(
		!held_effects(host, source).await.iter().any(|id| id == "effect-stalled"),
		"a swept receipt keeps no place for its source either"
	);
	assert_eq!(
		host.send(
			source,
			"release-inert-effect",
			&[source.clone().into(), "effect-stalled".into(), sent_by.clone().into()],
		)
		.await
		.unwrap(),
		Argument::String("released".into()),
		"a second sweep's release changes nothing"
	);
	assert_eq!(
		revision(host, source).await,
		swept,
		"a second sweep's release writes nothing"
	);
	given_up(host, source, "effect-stalled").await;
	assert!(workspace.recover_effect("effect-stalled").await.unwrap().is_none());
	assert_eq!(unknown.release().await.unwrap(), Release::Released);
	assert!(
		workspace
			.effects()
			.await
			.unwrap()
			.iter()
			.any(|row| row.operation == "effect-cold" && !row.resumable && row.status == EffectStatus::Unknown),
		"a released receipt stays in the inventory, unknown for good"
	);

	assert!(workspace.recover_effect("effect-cold").await.unwrap().is_none());
	assert!(unknown.resume().await.is_err(), "a released receipt cannot resume");
	assert_eq!(
		unknown.release().await.unwrap(),
		Release::Released,
		"a retried release answers released"
	);
	assert!(workspace.recover_effect("effect-cold").await.unwrap().is_none());
	let snapshot = workspace.snapshot().await.unwrap();
	assert!(!committed.adopted().await.unwrap());
	let acquisition = committed
		.prepare_result_acquisition_with_source(snapshot.revision, &[], &[], &snapshot.intent, None)
		.unwrap();
	acquisition.submit().await.unwrap();
	assert!(committed.adopted().await.unwrap());
	assert!(
		workspace.recover_effect("effect-root").await.unwrap().is_none(),
		"adopted receipts require no recovery"
	);
	let adopted_revision = workspace.snapshot().await.unwrap().revision;
	assert!(adopted_revision > snapshot.revision);
	acquisition.submit().await.unwrap();
	assert_eq!(workspace.snapshot().await.unwrap().revision, adopted_revision);
	// Even a newly prepared candidate cannot reinterpret a completed adoption.
	let mut changed = snapshot.intent.clone();
	changed.standing = rooms_application::fields::Text::new("different".into()).unwrap();
	committed
		.prepare_result_acquisition_with_source(snapshot.revision, &[], &[], &changed, None)
		.unwrap()
		.submit()
		.await
		.unwrap();
	assert_eq!(workspace.snapshot().await.unwrap().revision, adopted_revision);
	assert_eq!(calls.get(), 0, "receipt recovery cannot recreate an upstream dispatch");
}
