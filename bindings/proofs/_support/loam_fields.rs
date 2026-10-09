//! One field-authoring consumer trace shared by TCP/LMDB and Chromium/IndexedDB.
//! Shared Zig reference scenarios own exact authority and transaction semantics.
use super::{
	Argument, Call, Graph, HostResult as Result, InvocationBounds, Method, Ref, ReferenceRequest, Retry, Session,
	StagingBounds, ValueBounds, refusal,
};

pub fn sizing() {
	let content = StagingBounds::content(1, true).unwrap();
	assert_eq!(content.changes, 6);
	let recipes = StagingBounds::references(3592).unwrap();
	assert_eq!(recipes.changes + 64 + content.changes, 3662);
	assert!(recipes.record_bytes < content.record_bytes);
	assert!(StagingBounds::content(0, true).is_err());
	assert!(StagingBounds::references(usize::MAX).is_err());
	assert_eq!(StagingBounds::references(0).unwrap().staging_bytes, 0);
	let empty = ReferenceRequest::call_size_bound(0, 0, 0).unwrap();
	assert_ne!(empty, 0, "empty declarations still own preparation state");
	let maximum = ReferenceRequest::call_size_bound(3592, 3592, 4096).unwrap();
	assert!(maximum > empty);
	for (restores, saves, uri) in [(1, 1, 4097), (usize::MAX, 1, 4096), (0, usize::MAX, 0)] {
		assert!(ReferenceRequest::call_size_bound(restores, saves, uri).is_err());
	}
	let empty_graph = Graph::call_size_bound(0, 0, 0).unwrap();
	assert_ne!(
		empty_graph, 0,
		"empty graphs still prepare state and stage a root binding"
	);
	assert!(Graph::call_size_bound(63, 1024 * 1024, 3592).unwrap() > empty_graph);
	for (pages, payload, fields) in [(usize::MAX, 0, 0), (1, usize::MAX, 0), (1, 0, usize::MAX)] {
		assert!(Graph::call_size_bound(pages, payload, fields).is_err());
	}
	let invocation = |values, held| InvocationBounds {
		arguments: ValueBounds {
			values,
			bytes: 3,
			..ValueBounds::default()
		},
		reply: ValueBounds {
			values: 1,
			..ValueBounds::default()
		},
		verb_bytes: 6,
		held_occurrences: held,
		receipt: true,
		dependent: false,
	};
	let small = invocation(3, 0).call_size_bound().unwrap();
	assert!(invocation(3, 3592).call_size_bound().unwrap() > small);
	assert!(invocation(usize::MAX, 0).call_size_bound().is_err());
	assert!(invocation(3, usize::MAX).call_size_bound().is_err());
}

pub fn methods() -> Vec<Method> {
	[
		"field",
		"dependent",
		"append",
		"append-live",
		"replace-field",
		"fail-field",
		"remove-field",
	]
	.into_iter()
	.map(|verb| Method {
		verb: verb.into(),
		retry: if verb == "field" || verb == "dependent" {
			Retry::ReadOnly
		} else {
			Retry::Idempotent
		},
	})
	.collect()
}
pub fn handles(verb: &str) -> bool {
	[
		"field",
		"dependent",
		"append",
		"append-live",
		"replace-field",
		"fail-field",
		"remove-field",
	]
	.contains(&verb)
}
fn reference(args: &[Argument]) -> Result<Ref> {
	args.first()
		.and_then(|value| Ref::try_from(value).ok())
		.ok_or_else(|| refusal("expected held reference"))
}
fn index(args: &[Argument]) -> Result<usize> {
	args.first()
		.and_then(Argument::as_i64)
		.and_then(|n| usize::try_from(n).ok())
		.ok_or_else(|| refusal("expected field index"))
}

pub fn requests(verb: &str, args: &[Argument]) -> Result<Vec<ReferenceRequest>> {
	match verb {
		"field" | "dependent" => Ok(vec![ReferenceRequest::Restore(index(args)?)]),
		"append" | "replace-field" | "fail-field" => Ok(vec![ReferenceRequest::Save {
			reference: reference(args)?,
			uri: args.get(1).and_then(Argument::as_str).map(str::to_owned),
		}]),
		"append-live" => Ok(vec![ReferenceRequest::SaveLive(reference(args)?)]),
		_ => Ok(Vec::new()),
	}
}
pub fn invoke(call: &mut Call<'_>, verb: &str, args: &[Argument]) -> Result<Argument> {
	match verb {
		"field" | "dependent" => call.disclose(index(args)?, verb == "dependent"),
		"append" | "append-live" => {
			call.append_reference(&reference(args)?)?;
			Ok(Argument::Boolean(true))
		}
		"replace-field" | "fail-field" => {
			call.replace_reference(0, &reference(args)?)?;
			if verb == "fail-field" {
				call.replace(b"refused")?;
				return Err(refusal("refuse after staging field"));
			}
			Ok(Argument::Boolean(true))
		}
		"remove-field" => {
			call.remove_reference(0)?;
			Ok(Argument::Boolean(true))
		}
		_ => Err(refusal("unknown field method")),
	}
}

pub async fn live(session: &Session, root: &Ref, target: &Ref) {
	session
		.send(root, "append-live", &[Argument::Reference(target.clone())])
		.await
		.unwrap();
	assert_eq!(
		field(session, root, 1, false).await,
		*target,
		"live restoration returns the actual saved capability"
	);
	session
		.send(root, "append-live", &[Argument::Reference(root.clone())])
		.await
		.unwrap();
	assert_eq!(field(session, root, 2, false).await, *root);
}

pub async fn expired_live(session: &Session, root: &Ref) {
	for index in [1, 2] {
		let error = session
			.send(root, "field", &[Argument::Integer(index)])
			.await
			.unwrap_err();
		assert_eq!(error.message(), Some("LiveReferenceExpired"));
	}
}
async fn field(session: &Session, root: &Ref, index: i64, dependent: bool) -> Ref {
	Ref::try_from(
		&session
			.send(
				root,
				if dependent { "dependent" } else { "field" },
				&[Argument::Integer(index)],
			)
			.await
			.unwrap(),
	)
	.unwrap()
}
async fn name(session: &Session, reference: &Ref) -> String {
	session
		.send(reference, "durable-name", &[])
		.await
		.unwrap()
		.as_str()
		.unwrap()
		.to_owned()
}
pub async fn exercise(
	session: &Session,
	root: &Ref,
	target: &Ref,
	write_target: &Ref,
	target_control: &Ref,
	live: &Ref,
) -> (String, super::context::Stamp) {
	sizing();
	assert!(
		session
			.send(root, "append", &[Argument::Reference(live.clone())])
			.await
			.is_err()
	);
	assert!(session.send(root, "field", &[Argument::Integer(0)]).await.is_err());
	session
		.send(root, "append", &[Argument::Reference(target.clone())])
		.await
		.unwrap();
	let exact = field(session, root, 0, false).await;
	let target_name = name(session, target).await;
	assert_eq!(
		name(session, &exact).await,
		target_name,
		"append preserves the exact held grant"
	);
	assert!(
		session
			.send(
				&exact,
				"mutate",
				&[
					Argument::Integer(1),
					Argument::String("set".into()),
					Argument::Bytes(b"widened".to_vec())
				]
			)
			.await
			.is_err(),
		"saved read authority cannot become write authority"
	);
	assert!(
		session
			.send(root, "fail-field", &[Argument::Reference(write_target.clone())])
			.await
			.is_err()
	);
	assert_eq!(
		name(session, &field(session, root, 0, false).await).await,
		target_name,
		"refused callback commits no field replacement"
	);
	session
		.send(root, "replace-field", &[Argument::Reference(write_target.clone())])
		.await
		.unwrap();
	assert_eq!(
		name(session, &field(session, root, 0, false).await).await,
		name(session, write_target).await
	);
	session
		.send(root, "replace-field", &[Argument::Reference(target.clone())])
		.await
		.unwrap();
	let dependent = field(session, root, 0, true).await;
	let root_context = super::context::snapshot(session, root).await;
	super::context::same_resource(&root_context, &super::context::snapshot(session, &exact).await);
	super::context::same_resource(&root_context, &super::context::snapshot(session, &dependent).await);
	assert!(session.send(&dependent, "get", &[]).await.is_ok());
	session
		.send(
			target_control,
			"pause",
			&[Argument::Bytes(
				super::management::revision(session, target_control)
					.await
					.to_be_bytes()
					.to_vec(),
			)],
		)
		.await
		.unwrap();
	assert!(
		session.send(&exact, "get", &[]).await.is_err(),
		"exact restoration still checks the target grant"
	);
	assert!(session.send(&dependent, "get", &[]).await.is_err());
	session
		.send(
			target_control,
			"resume",
			&[Argument::Bytes(
				super::management::revision(session, target_control)
					.await
					.to_be_bytes()
					.to_vec(),
			)],
		)
		.await
		.unwrap();
	session.send(root, "remove-field", &[]).await.unwrap();
	assert!(session.send(root, "field", &[Argument::Integer(0)]).await.is_err());
	assert!(
		session.send(&exact, "get", &[]).await.is_ok(),
		"removal releases local custody without revoking independently held authority"
	);
	session
		.send(root, "append", &[Argument::Reference(target.clone())])
		.await
		.unwrap();
	(target_name, root_context)
}
pub async fn reopen(session: &Session, root: &Ref, expected: &str, initial: &super::context::Stamp) {
	let restored = field(session, root, 0, false).await;
	assert_eq!(
		name(session, &restored).await,
		expected,
		"cold restoration preserves the exact saved grant"
	);
	assert!(session.send(&restored, "get", &[]).await.is_ok());
	let root_context = super::context::snapshot(session, root).await;
	super::context::same_resource(initial, &root_context);
	super::context::same_resource(&root_context, &super::context::snapshot(session, &restored).await);
}
