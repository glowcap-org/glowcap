//! Sender identity and line custody survive eviction of the original receipt.
use super::*;
pub(super) async fn after_post(
	host: &Host,
	source: &Ref,
	other: &Ref,
	changed_lines: &Rc<Cell<usize>>,
	platform: &Platform,
) {
	let posted = host.send(source, "snapshot", &[]).await.unwrap();
	let posted: Intent = serde_json::from_str(posted.as_list().unwrap()[1].as_str().unwrap()).unwrap();
	let authored = posted.conversations.as_slice()[0].lines()[0].id.get();
	let workspace = rooms_glowcap::client::workspace::Workspace::local(host.clone(), platform.clone(), source.clone());
	let recovered = workspace
		.recover_effect("posted")
		.await
		.unwrap()
		.expect("unadopted line");
	let snapshot = workspace.snapshot().await.unwrap();
	recovered
		.prepare_result_acquisition_with_source(snapshot.revision, &[], &[], &snapshot.intent, None)
		.unwrap()
		.submit()
		.await
		.unwrap();
	for ordinal in 0..=custody::MAX_EFFECTS {
		let (args, _) = command(
			host,
			source,
			&format!("advance-{ordinal}"),
			"setDraft",
			&["direct".into(), format!("draft-{ordinal}")],
		)
		.await;
		mutate(host, source, "command", &args).await.unwrap();
	}
	assert!(
		host.send(source, "effect-status", &["posted".into(), source.clone().into()])
			.await
			.is_err(),
		"the original receipt must really leave the window"
	);
	assert!(
		workspace.recover_effect("posted").await.unwrap().is_none(),
		"inventory expiry is explicit absence, never a resend"
	);
	for (operation, verb, extra) in [
		("edited-sender", "editLine", Some("sender edit after receipt eviction")),
		("withdrawn-sender", "withdrawLine", None),
	] {
		let mut values = vec!["direct".into(), authored.to_string()];
		if let Some(text) = extra {
			values.push(text.into());
		}
		let (args, _) = command(host, source, operation, verb, &values).await;
		if verb == "withdrawLine" {
			platform.suspended.set(true);
		}
		mutate(host, source, "command", &args).await.unwrap();
		if verb == "withdrawLine" {
			let (duplicate, _) = command(host, source, "concurrent-withdraw", verb, &values).await;
			assert!(
				mutate(host, source, "command", &duplicate).await.is_err(),
				"a line has only one pending metadata change"
			);
			let snapshot = host.send(source, "snapshot", &[]).await.unwrap();
			let mut intent: Intent = serde_json::from_str(snapshot.as_list().unwrap()[1].as_str().unwrap()).unwrap();
			let session::workspace::Conversation::Direct(direct) = &mut intent.conversations.as_mut_slice()[0] else {
				panic!("sender direct")
			};
			let key = direct.lines.as_slice()[0].handle;
			direct.lines = List::default();
			let coordinate = custody::Coordinate {
				role: custody::Role::Line,
				key: custody::FieldKey::new(key.slot(), key.generation()),
			};
			mutate(
				host,
				source,
				"release",
				&[
					serde_json::to_string(&coordinate).unwrap().into(),
					serde_json::to_string(&intent).unwrap().into(),
				],
			)
			.await
			.unwrap();
			platform.suspended.set(false);
		}
		assert_eq!(
			finished(host, other, operation, source).await.as_str(),
			Some("committed")
		);
	}
	assert_eq!(
		changed_lines.get(),
		2,
		"retained line custody survives receipt eviction"
	);
	let snapshot = host.send(source, "snapshot", &[]).await.unwrap();
	let intent: Intent = serde_json::from_str(snapshot.as_list().unwrap()[1].as_str().unwrap()).unwrap();
	assert!(
		intent.conversations.as_slice()[0].lines().is_empty(),
		"late successful withdrawal settles without resurrecting released sender custody"
	);
}
