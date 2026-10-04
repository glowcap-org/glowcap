//! One field-authoring consumer trace shared by TCP/LMDB and Chromium/IndexedDB.
//! Shared Zig reference scenarios own exact authority and transaction semantics.
use super::{Argument, Call, HostResult as Result, Method, Ref, ReferenceRequest, Retry, Session, refusal};

pub fn methods() -> Vec<Method> {
	[
		"field",
		"dependent",
		"append",
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
		_ => Ok(Vec::new()),
	}
}
pub fn invoke(call: &mut Call<'_>, verb: &str, args: &[Argument]) -> Result<Argument> {
	match verb {
		"field" | "dependent" => call.disclose(index(args)?, verb == "dependent"),
		"append" => {
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
) -> String {
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
	assert!(session.send(&dependent, "get", &[]).await.is_ok());
	session.send(target_control, "pause", &[]).await.unwrap();
	assert!(
		session.send(&exact, "get", &[]).await.is_err(),
		"exact restoration still checks the target grant"
	);
	assert!(session.send(&dependent, "get", &[]).await.is_err());
	session.send(target_control, "resume", &[]).await.unwrap();
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
	target_name
}
pub async fn reopen(session: &Session, root: &Ref, expected: &str) {
	let restored = field(session, root, 0, false).await;
	assert_eq!(
		name(session, &restored).await,
		expected,
		"cold restoration preserves the exact saved grant"
	);
	assert!(session.send(&restored, "get", &[]).await.is_ok());
}
