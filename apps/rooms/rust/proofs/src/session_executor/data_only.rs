//! A data-only kind's result keeps no capability, checked on the first
//! settlement of a receipt.
use super::*;

/// A first settlement of `case`'s unresolved `operation` that gives a
/// data-only kind's result a capability is refused, and the receipt stays
/// unresolved. A committed receipt refuses any different settlement anyway,
/// so only an unresolved one shows the kind's own check.
pub(super) async fn settlement(host: &Host, root: &Ref, case: &Case, operation: &str, base: i64) {
	let request = rooms_application::session::command::Request::from_parts(
		operation,
		base.try_into().unwrap(),
		case.name,
		&case.args,
	)
	.unwrap();
	let Some(reply) = managed::command_reply(&request) else {
		panic!("{} settles with a kind", case.name)
	};
	if reply.may_retain_capabilities() {
		return;
	}
	let canonical = serde_json::to_string(&(operation, base, case.name, &case.args)).unwrap();
	let coordinate = serde_json::to_string(&custody::Coordinate {
		role: case.role,
		key: key(),
	})
	.unwrap();
	let outcome = Argument::List(vec![
		case.retained_result().into(),
		Argument::List(vec![Argument::List(vec![
			coordinate.into(),
			Argument::Reference(root.clone()),
			// The recipe the role's lifetime admits, so only the data-only
			// check can refuse the field.
			if case.role.live() {
				Argument::List(vec!["live".into()])
			} else {
				Argument::Void
			},
		])]),
	]);
	let before = host.send(root, "snapshot", &[]).await.unwrap();
	let refusal = host
		.send(
			root,
			"settle-effect",
			&[
				operation.into(),
				root.clone().into(),
				canonical.into(),
				outcome,
				Argument::Void,
			],
		)
		.await
		.expect_err("a data-only kind's settlement carrying a capability is refused");
	assert!(
		refusal
			.to_string()
			.contains("result of a data-only kind carries a capability"),
		"{} is refused by the data-only check, not another: {refusal}",
		case.name
	);
	assert_eq!(host.send(root, "snapshot", &[]).await.unwrap(), before);
	assert_eq!(
		host.send(
			root,
			"effect-status",
			&[operation.into(), Argument::Reference(root.clone())]
		)
		.await
		.unwrap()
		.as_str(),
		Some("unknown"),
		"the refused settlement left the receipt unresolved"
	);
}
