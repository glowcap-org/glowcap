use glowcap::{Argument, CaptpVersion, Locator};
use rooms_application::room::authority;
use std::{cell::Cell, cell::RefCell, rc::Rc};
#[derive(Clone)]
pub struct Managed {
	pub room_link: String,
	pub manager_link: String,
	pub kicked: Rc<RefCell<Vec<String>>>,
}
pub fn publish(host: &glowcap::Host, locator: &Locator, acted: Rc<RefCell<Vec<String>>>) -> Managed {
	let room_link = glowcap::format_sturdyref(locator, b"managed-room", CaptpVersion::V1_0).unwrap();
	let manager_link = glowcap::format_sturdyref(locator, b"managed-mgr", CaptpVersion::V1_0).unwrap();
	let identity = authority::room_identity("managed-room").unwrap();
	let kicked = Rc::new(RefCell::new(Vec::new()));
	let inbox = Rc::new(RefCell::new(None::<glowcap::Ref>));
	let next_line = Rc::new(Cell::new(0u64));
	let room_answer = room_link.clone();
	let identity_answer = identity.clone();
	host.publish_giftable("managed-room", {
		let kicked = kicked.clone();
		let inbox = inbox.clone();
		let next_line = next_line.clone();
		move || {
			let (kicked, inbox, next_line, room_answer, identity_answer) = (
				kicked.clone(),
				inbox.clone(),
				next_line.clone(),
				room_answer.clone(),
				identity_answer.clone(),
			);
			Box::new(move |verb, args| match verb {
				"subscribe" => subscribe(&inbox, &next_line, args),
				"roomPolicy" => Ok(Argument::List(vec![
					"secret".into(),
					"invite-only".into(),
					"moderated".into(),
				])),
				"link" => Ok(room_answer.clone().into()),
				authority::MANAGED_IDENTITY => Ok(identity_answer.clone().into()),
				authority::KICK => {
					kicked
						.borrow_mut()
						.push(args.first().and_then(Argument::as_str).unwrap_or("").into());
					Ok(Argument::Void)
				}
				_ => Err("unknown managed room verb".into()),
			})
		}
	})
	.unwrap();
	let manager_room = room_link.clone();
	let manager_identity = identity.clone();
	let steward_link = glowcap::format_sturdyref(locator, b"managed-steward", CaptpVersion::V1_0).unwrap();
	let grant_room = manager_room.clone();
	let grant_identity = manager_identity.clone();
	let grant_steward = steward_link.clone();
	let log = acted.clone();
	host.publish_giftable("managed-mgr", move || {
		let (grant_room, grant_identity, grant_steward, log, manager_room, manager_identity) = (
			grant_room.clone(),
			grant_identity.clone(),
			grant_steward.clone(),
			log.clone(),
			manager_room.clone(),
			manager_identity.clone(),
		);
		Box::new(move |verb, args| {
			if !matches!(verb, authority::GOVERNS | authority::LINK) {
				log.borrow_mut().push(format!("manager:{verb}"));
			}
			match verb {
				authority::GOVERNS => Ok(manager_identity.clone().into()),
				authority::LINK => Ok(manager_room.clone().into()),
				authority::GIVE_STEWARD => Ok(Argument::List(vec![
					grant_room.clone().into(),
					grant_identity.clone().into(),
					grant_steward.clone().into(),
				])),
				authority::SET_POLICY => {
					let name = args.get(4).and_then(Argument::as_str).unwrap_or("managed");
					let vis = args.get(1).and_then(Argument::as_str).unwrap_or("secret");
					let entry = args.get(2).and_then(Argument::as_str).unwrap_or("invite-only");
					let speaking = args.get(3).and_then(Argument::as_str).unwrap_or("moderated");
					Ok(Argument::List(vec![
						name.into(),
						vis.into(),
						entry.into(),
						speaking.into(),
					]))
				}
				authority::UNREGISTER_ROOM => Ok(Argument::List(vec![
					"managed".into(),
					"listed".into(),
					"open".into(),
					"open".into(),
				])),
				authority::REVOKE_ROOM_LINK | authority::REVOKE_STEWARD => Ok(Argument::Void),
				_ => Err(format!("unknown manager method {verb}")),
			}
		})
	})
	.unwrap();
	host.publish_giftable("managed-steward", {
		let identity = identity.clone();
		let kicked = kicked.clone();
		move || {
			let (identity, kicked) = (identity.clone(), kicked.clone());
			Box::new(move |verb, args| match verb {
				authority::GOVERNS => Ok(identity.clone().into()),
				authority::KICK => {
					kicked
						.borrow_mut()
						.push(args.first().and_then(Argument::as_str).unwrap_or("").into());
					Ok(Argument::Void)
				}
				_ => Err("unknown steward method".into()),
			})
		}
	})
	.unwrap();
	Managed {
		room_link,
		manager_link,
		kicked,
	}
}

fn subscribe(
	inbox: &Rc<RefCell<Option<glowcap::Ref>>>,
	next_line: &Rc<Cell<u64>>,
	args: &[Argument],
) -> Result<Argument, String> {
	let nick = args.first().cloned().unwrap_or_else(|| "alice".into());
	let Argument::Reference(callback) = &args[1] else {
		return Err("subscription omitted its inbox".into());
	};
	*inbox.borrow_mut() = Some(callback.clone());
	let callback = callback.clone();
	let hosted = glowcap::current_session()
		.map_err(|e| e.to_string())?
		.ok_or("managed room subscribe needs a session")?;
	let seat = seat(&hosted, inbox.clone(), next_line.clone());
	tokio::task::spawn_local(async move {
		let _ = hosted
			.send(
				&callback,
				rooms_application::room::inbox::NOTIFY,
				&["room".into(), "".into(), "listed".into(), Argument::Boolean(false)],
			)
			.await;
		let _ = hosted
			.send(
				&callback,
				rooms_application::room::inbox::NOTIFY,
				&["room".into(), "".into(), "roster".into(), nick],
			)
			.await;
	});
	// The double answers the file verbs on its seat, so the seat stands in for
	// the files facet the real room hands over separately.
	Ok(Argument::List(vec![
		seat.clone().into(),
		"participant".into(),
		Argument::Void,
		seat.into(),
	]))
}

fn seat(
	session: &glowcap::Session,
	inbox: Rc<RefCell<Option<glowcap::Ref>>>,
	next_line: Rc<Cell<u64>>,
) -> glowcap::Ref {
	session
		.spawn_owned(move |verb, _| match verb {
			"post" | "postFiles" => {
				let id = next_line.get() + 1;
				next_line.set(id);
				let hosted = glowcap::current_session().ok().flatten();
				if let (Some(hosted), Some(inbox)) = (hosted, inbox.borrow().clone()) {
					tokio::task::spawn_local(async move {
						let _ = hosted
							.send(
								&inbox,
								rooms_application::room::inbox::NOTIFY,
								&["alice".into(), "".into(), "line".into(), Argument::Integer(id as i64)],
							)
							.await;
					});
				}
				Ok(Argument::Void)
			}
			"typing" | "leave" | "away" | "attach" => Ok(Argument::Void),
			_ => Err("unknown managed seat verb".into()),
		})
		.unwrap()
}
