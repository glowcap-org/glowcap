use glowcap::Argument;
use std::{cell::RefCell, rc::Rc};
pub fn publish(session: &glowcap::Session, published: Rc<RefCell<Vec<String>>>) -> Vec<glowcap::Ref> {
	let snapshot = operator_snapshot();
	let peering = session.borrowed();
	let leases = session.borrowed();
	let operator_log = published.clone();
	let listener_log = published.clone();
	let irc_log = published.clone();
	vec![
		session
			.publish("operator", move |verb, args| {
				if !matches!(verb, "watch" | "unwatch" | "operatorSnapshot") {
					operator_log.borrow_mut().push(format!("operator:{verb}"));
				}
				match verb {
					"watch" | "unwatch" => Ok(Argument::Void),
					"operatorSnapshot" if args.len() >= 3 => Ok(Argument::List(vec![
						1.into(),
						Argument::Void,
						Argument::List(vec![]),
						0.into(),
					])),
					"operatorSnapshot" => Ok(snapshot.clone()),
					"operatorRetireMatching" => Ok(Argument::List(vec![0.into(), 0.into(), "".into()])),
					"revokeRoomLink"
					| "revokeRoomAuthority"
					| "revokeNick"
					| "disconnectSession"
					| "removeOperatorRoom"
					| "releaseOperatorReference"
					| "clearOperatorTrouble"
					| "resetOperatorScope"
					| "giveSteward"
					| "revokeSteward" => Ok(Argument::Void),
					_ => Err(format!("unknown operator method {verb}")),
				}
			})
			.unwrap(),
		session
			.publish("listeners", move |verb, args| {
				listener_log.borrow_mut().push(format!(
					"listeners:{verb}:{}",
					args.first().and_then(Argument::as_str).unwrap_or("")
				));
				match verb {
					"list" => Ok(Argument::List(vec![])),
					"up" | "down" => Ok(Argument::Void),
					_ => Err(format!("unknown listeners method {verb}")),
				}
			})
			.unwrap(),
		session
			.publish("diagnostics", |verb, _| match verb {
				"snapshot" => Ok(Argument::List(vec![])),
				_ => Err(format!("unknown diagnostics method {verb}")),
			})
			.unwrap(),
		session
			.publish("irc", move |verb, _| {
				irc_log.borrow_mut().push(format!("irc:{verb}"));
				match verb {
					"snapshot" => Ok("{}".into()),
					"openConnection" => Ok("conn-1".into()),
					"connection" => Err("no such connection".into()),
					_ => Err(format!("unknown irc method {verb}")),
				}
			})
			.unwrap(),
		peering
			.publish("peering", move |verb, args| match verb {
				"publishDurableRoom" => {
					let name = args.first().and_then(Argument::as_str).unwrap_or("").to_owned();
					published.borrow_mut().push(format!("publishDurableRoom:{name}"));
					let published = published.clone();
					let lease = leases
						.spawn_owned(move |verb, _| match verb {
							"ready" => {
								published.borrow_mut().push("ready".into());
								Ok(Argument::Void)
							}
							"revoke" => {
								published.borrow_mut().push("revoke".into());
								Ok(Argument::Void)
							}
							_ => Err("unknown publication lease method".into()),
						})
						.map_err(|e| e.to_string())?;
					Ok(lease.into())
				}
				_ => Err(format!("unknown peering method {verb}")),
			})
			.unwrap(),
	]
}

fn operator_snapshot() -> Argument {
	const CATEGORIES: [&str; 7] = [
		"stewardships",
		"links",
		"registrations",
		"sessions",
		"rooms",
		"references",
		"trouble",
	];
	Argument::List(vec![
		Argument::Integer(1),
		Argument::List(
			CATEGORIES
				.into_iter()
				.map(|category| {
					Argument::List(vec![
						category.into(),
						Argument::Void,
						Argument::List(vec![]),
						Argument::Integer(0),
					])
				})
				.collect(),
		),
	])
}
