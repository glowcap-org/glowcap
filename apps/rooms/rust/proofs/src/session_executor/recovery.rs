//! Recovery uses actual source custody, including after a physical Store reopen.
use super::*;
use rooms_glowcap::client::workspace::{EffectStatus, Workspace};

pub(super) async fn resume(host: &Host, source: &Ref, sibling: &Ref, canonical: &str) {
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
		recovered.release().await.is_err(),
		"a paused executor still owns its admitted effect and cannot lose its receipt"
	);
	assert_eq!(recovered.status().await.unwrap(), EffectStatus::Unknown);
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
	assert!(
		recovered.release().await.is_err(),
		"a receipt whose executor is running cannot be released"
	);
	assert_eq!(recovered.status().await.unwrap(), EffectStatus::Pending);
}
pub(super) async fn cold(host: &Host, source: &Ref, result: &str, calls: &Cell<usize>, departed: bool) {
	let workspace = Workspace::local(host.clone(), Platform::default(), source.clone());
	let rows = workspace.effects().await.unwrap();
	let mut operations = rows.iter().map(|row| row.operation.as_str()).collect::<Vec<_>>();
	operations.sort_unstable();
	let mut expected = vec!["effect-cold", "effect-root"];
	if departed {
		expected.insert(0, "departure");
	}
	assert_eq!(
		operations, expected,
		"cold inventory contains exactly the root's receipts"
	);
	assert!(rows.iter().all(|row| !row.resumable));
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
	unknown.release().await.unwrap();
	assert!(
		workspace
			.effects()
			.await
			.unwrap()
			.iter()
			.all(|row| row.operation != "effect-cold"),
		"a released receipt leaves the inventory"
	);
	assert!(workspace.recover_effect("effect-cold").await.unwrap().is_none());
	assert!(unknown.resume().await.is_err(), "a released receipt cannot resume");
	unknown.release().await.expect("a retried release answers done");
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
