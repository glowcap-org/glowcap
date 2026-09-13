use super::{REGISTRATION, managed::Managed};
use glowcap::Argument;
use rooms_application::room::inbox::NOTIFY;
use std::{cell::Cell, cell::RefCell, rc::Rc};
const BRIDGE_FORM: &str = concat!(
	r#"{"scope":"network","title":"Identity","said":"test","#,
	r#"fields":[{"kind":"secret","id":"password","label":"Password","required":true}],"#,
	r#"actions":[{"id":"link","label":"Link","busyLabel":"Linking","tone":"primary","remembered":true},"#,
	r#"{"id":"disconnect","label":"Disconnect","busyLabel":"Disconnecting","tone":"quiet","remembered":true}]}"#,
);
#[allow(clippy::too_many_arguments)]
pub fn publish(
	session: &glowcap::Session,
	garden_link: &str,
	received: Rc<RefCell<Vec<String>>>,
	published: Rc<RefCell<Vec<String>>>,
	reciprocal: Rc<RefCell<Option<(glowcap::Session, glowcap::Ref)>>>,
	allow_managed: Rc<Cell<bool>>,
	managed: Managed,
	room_inbox: RoomInbox,
	room_subscriptions: Rc<Cell<u32>>,
	bridge_calls: Rc<RefCell<Vec<(String, String)>>>,
) -> (glowcap::Ref, Vec<glowcap::Ref>) {
	let name = session
		.spawn_owned(|verb, _| {
			assert_eq!(verb, "voucher");
			Ok(Argument::Bytes(vec![1, 9]))
		})
		.unwrap();
	let inbox = Rc::new(RefCell::new(None::<glowcap::Ref>));
	let next_line = Rc::new(Cell::new(0u64));
	let staged = Rc::new(RefCell::new(Vec::<Staged>::new()));
	let seat = garden_seat(session, inbox.clone(), next_line.clone(), staged, bridge_calls);
	let room = garden_room(
		session,
		inbox,
		seat.clone(),
		garden_link.to_owned(),
		room_inbox,
		room_subscriptions,
	);
	let direct = direct_inbox(session, received, reciprocal);
	let managed_room = managed.room_link.clone();
	let managed_manager = managed.manager_link.clone();
	let name_held = name.clone();
	let room_held = room.clone();
	let direct_held = direct.clone();
	let offered = RefCell::new(None::<glowcap::Ref>);
	let root = session
		.publish("directory", move |verb, args| match verb {
			"watchPublications" => Ok(Argument::List(vec![
				Argument::List(vec![Argument::List(vec!["garden".into(), 1.into()])]),
				Argument::List(vec![]),
				0.into(),
			])),
			"register" => {
				let Argument::Reference(inbox) = &args[2] else {
					panic!("registration callback")
				};
				glowcap::current_session()
					.unwrap()
					.unwrap()
					.tell(
						inbox,
						"notify",
						&["registered".into(), args[0].clone(), REGISTRATION.into()],
					)
					.unwrap();
				Ok(name_held.clone().into())
			}
			"offerInbox" => {
				let [
					Argument::String(peer),
					Argument::String(registration),
					Argument::Reference(inbox),
				] = args
				else {
					panic!("inbox offer must carry its peer, registration, and capability");
				};
				assert_eq!(peer, "bob");
				assert_eq!(registration, REGISTRATION);
				*offered.borrow_mut() = Some(inbox.clone());
				Ok(Argument::Void)
			}
			"introduce" => Ok(direct_held.clone().into()),
			"memberRegistration" => Ok(REGISTRATION.into()),
			"requestDirect" => Ok(Argument::Void),
			"enter" | "open" | "enterPublication" => Ok(room_held.clone().into()),
			"openManaged" => open_managed(&allow_managed, &published, &managed_room, &managed_manager),
			_ => Err(format!("unknown directory method {verb}")),
		})
		.unwrap();
	(root, vec![name, seat, room, direct])
}

struct Staged {
	name: String,
	mime: String,
	size: u64,
	width: i64,
	height: i64,
	bytes: Rc<RefCell<Vec<u8>>>,
}

fn garden_line(hosted: &glowcap::Session, inbox: Rc<RefCell<Option<glowcap::Ref>>>, id: u64) -> glowcap::Ref {
	let session = hosted.borrowed();
	let hosted = hosted.borrowed();
	session
		.spawn_owned(move |verb, args| match verb {
			"edit" | "withdraw" => Ok(Argument::Void),
			"refile" => {
				let caption = args.first().and_then(Argument::as_str).unwrap_or("").to_owned();
				if let Some(inbox) = inbox.borrow().clone() {
					let hosted = hosted.borrowed();
					tokio::task::spawn_local(async move {
						let _ = hosted
							.send(
								&inbox,
								NOTIFY,
								&[
									"alice".into(),
									caption.into(),
									"line".into(),
									Argument::Integer(id as i64),
								],
							)
							.await;
					});
				}
				Ok(Argument::Void)
			}
			_ => Err("unknown line verb".into()),
		})
		.unwrap()
}

fn garden_seat(
	session: &glowcap::Session,
	inbox: Rc<RefCell<Option<glowcap::Ref>>>,
	next_line: Rc<Cell<u64>>,
	staged: Rc<RefCell<Vec<Staged>>>,
	bridge_calls: Rc<RefCell<Vec<(String, String)>>>,
) -> glowcap::Ref {
	let hosted = session.borrowed();
	session
		.spawn_owned(move |verb, args| match verb {
			"post" => post_text(&hosted, &inbox, &next_line, args),
			"attach" => attach(&hosted, &staged, args),
			"postFiles" => post_files(&hosted, &inbox, &next_line, &staged, args),
			"bridgeForm" => Ok(BRIDGE_FORM.into()),
			"submitBridgeForm" => {
				let action = args.first().and_then(Argument::as_str).unwrap_or("").to_owned();
				let answers = args.get(1).and_then(Argument::as_str).unwrap_or("").to_owned();
				bridge_calls.borrow_mut().push((action, answers.clone()));
				if answers.contains("slow horse") {
					let session = glowcap::current_session()
						.map_err(|error| error.to_string())?
						.ok_or("bridge submission needs a session")?;
					let mut deferred = session.host().defer_turn().map_err(|error| error.to_string())?;
					tokio::task::spawn_local(async move {
						tokio::time::sleep(std::time::Duration::from_secs(3)).await;
						let _ = deferred.fulfill(&Argument::Void);
					});
				}
				Ok(Argument::Void)
			}
			"typing" | "leave" | "away" => Ok(Argument::Void),
			_ => Err("unknown seat verb".into()),
		})
		.unwrap()
}

fn post_text(
	hosted: &glowcap::Session,
	inbox: &Rc<RefCell<Option<glowcap::Ref>>>,
	next_line: &Rc<Cell<u64>>,
	args: &[Argument],
) -> Result<Argument, String> {
	let text = args.first().and_then(Argument::as_str).unwrap_or("").to_owned();
	let id = next_line.get() + 1;
	next_line.set(id);
	let line = garden_line(hosted, inbox.clone(), id);
	if let Some(inbox) = inbox.borrow().as_ref() {
		let inbox = inbox.clone();
		let hosted = hosted.borrowed();
		tokio::task::spawn_local(async move {
			let _ = hosted
				.send(
					&inbox,
					NOTIFY,
					&["alice".into(), text.into(), "line".into(), Argument::Integer(id as i64)],
				)
				.await;
		});
	}
	Ok(line.into())
}

fn attach(hosted: &glowcap::Session, staged: &Rc<RefCell<Vec<Staged>>>, args: &[Argument]) -> Result<Argument, String> {
	let name = args.first().and_then(Argument::as_str).unwrap_or("file").to_owned();
	let mime = args
		.get(1)
		.and_then(Argument::as_str)
		.unwrap_or("application/octet-stream")
		.to_owned();
	let size = args.get(2).and_then(Argument::as_i64).unwrap_or(0).max(0) as u64;
	let width = args.get(3).and_then(Argument::as_i64).unwrap_or(0);
	let height = args.get(4).and_then(Argument::as_i64).unwrap_or(0);
	let bytes = Rc::new(RefCell::new(Vec::new()));
	let written = bytes.clone();
	staged.borrow_mut().push(Staged {
		name,
		mime,
		size,
		width,
		height,
		bytes,
	});
	hosted
		.spawn_owned(move |verb, args| match verb {
			"write" => {
				written
					.borrow_mut()
					.extend_from_slice(args.first().and_then(Argument::as_bytes).unwrap_or(&[]));
				Ok(Argument::Void)
			}
			"discard" => Ok(Argument::Void),
			_ => Err("unknown upload verb".into()),
		})
		.map(Argument::from)
		.map_err(|e| e.to_string())
}

fn post_files(
	hosted: &glowcap::Session,
	inbox: &Rc<RefCell<Option<glowcap::Ref>>>,
	next_line: &Rc<Cell<u64>>,
	staged: &Rc<RefCell<Vec<Staged>>>,
	args: &[Argument],
) -> Result<Argument, String> {
	let caption = args.first().and_then(Argument::as_str).unwrap_or("").to_owned();
	let files = staged.borrow_mut().split_off(0);
	let id = next_line.get() + 1;
	next_line.set(id);
	let line = garden_line(hosted, inbox.clone(), id);
	let Some(inbox) = inbox.borrow().clone() else {
		return Ok(line.into());
	};
	let mut notice = vec![
		"alice".into(),
		caption.into(),
		"line".into(),
		Argument::Integer(id as i64),
	];
	for file in &files {
		let blob = file_blob(hosted, file)?;
		notice.extend([
			"file".into(),
			file.name.clone().into(),
			file.mime.clone().into(),
			Argument::Integer(file.size as i64),
			blob.into(),
			Argument::Integer(file.width),
			Argument::Integer(file.height),
		]);
	}
	let hosted = hosted.borrowed();
	tokio::task::spawn_local(async move {
		let _ = hosted.send(&inbox, NOTIFY, &notice).await;
	});
	Ok(line.into())
}

fn file_blob(hosted: &glowcap::Session, file: &Staged) -> Result<glowcap::Ref, String> {
	let bytes = file.bytes.clone();
	let size = file.size as usize;
	hosted
		.spawn_owned(move |verb, args| {
			if verb != "read" {
				return Err("unknown file verb".into());
			}
			let offset = args.first().and_then(Argument::as_i64).unwrap_or(0).max(0) as usize;
			let length = args.get(1).and_then(Argument::as_i64).unwrap_or(0).max(0) as usize;
			let session = glowcap::current_session()
				.map_err(|e| e.to_string())?
				.ok_or("file read needs a session")?;
			let mut deferred = session.host().defer_turn().map_err(|e| e.to_string())?;
			let bytes = bytes.clone();
			tokio::task::spawn_local(async move {
				for _ in 0..200 {
					if bytes.borrow().len() >= size {
						break;
					}
					tokio::task::yield_now().await;
				}
				let held = bytes.borrow();
				let end = offset.saturating_add(length).min(held.len());
				let slice = held.get(offset..end).unwrap_or(&[]).to_vec();
				drop(held);
				let _ = deferred.fulfill(&Argument::Bytes(slice));
			});
			Ok(Argument::Void)
		})
		.map_err(|e| e.to_string())
}

/// The latest subscriber's inbox and the session it was delivered on, so a
/// test can speak for the room: end the membership, change the policy.
pub type RoomInbox = Rc<RefCell<Option<(glowcap::Session, glowcap::Ref)>>>;

fn garden_room(
	session: &glowcap::Session,
	inbox: Rc<RefCell<Option<glowcap::Ref>>>,
	seat: glowcap::Ref,
	room_link: String,
	room_inbox: RoomInbox,
	room_subscriptions: Rc<Cell<u32>>,
) -> glowcap::Ref {
	let hosted = session.borrowed();
	session
		.publish("garden-room", move |verb, args| match verb {
			"subscribe" => {
				room_subscriptions.set(room_subscriptions.get() + 1);
				let nick = args.first().cloned().unwrap_or_else(|| "alice".into());
				let Argument::Reference(callback) = &args[1] else {
					panic!("subscription omitted its inbox")
				};
				*inbox.borrow_mut() = Some(callback.clone());
				*room_inbox.borrow_mut() = Some((hosted.borrowed(), callback.clone()));
				let callback = callback.clone();
				let hosted = hosted.borrowed();
				tokio::task::spawn_local(async move {
					let _ = hosted
						.send(
							&callback,
							NOTIFY,
							&["room".into(), "".into(), "listed".into(), Argument::Boolean(false)],
						)
						.await;
					let _ = hosted
						.send(&callback, NOTIFY, &["room".into(), "".into(), "roster".into(), nick])
						.await;
				});
				// The double answers the file verbs on its seat, so the seat stands
				// in for the files facet the real room hands over separately.
				Ok(Argument::List(vec![
					seat.clone().into(),
					"participant".into(),
					Argument::Void,
					seat.clone().into(),
				]))
			}
			"roomPolicy" => Ok(Argument::List(vec!["listed".into(), "open".into(), "open".into()])),
			"link" => Ok(room_link.clone().into()),
			_ => Err("unknown room verb".into()),
		})
		.unwrap()
}

fn direct_inbox(
	session: &glowcap::Session,
	received: Rc<RefCell<Vec<String>>>,
	reciprocal: Rc<RefCell<Option<(glowcap::Session, glowcap::Ref)>>>,
) -> glowcap::Ref {
	let hosted = session.borrowed();
	session
		.spawn_owned(rooms_glowcap::client::direct::receiver(move |notice, delivering| {
			match notice {
				rooms_application::direct::Notice::Message { text, reply, .. } => {
					received.borrow_mut().push(text.into());
					if let Some(reply) = reply {
						*reciprocal.borrow_mut() = Some((hosted.borrowed(), reply.clone()));
					}
					let line = delivering
						.spawn_owned(|verb, _| match verb {
							"edit" | "withdraw" | "refile" => Ok(Argument::Void),
							_ => Err("unknown line verb".into()),
						})
						.unwrap();
					return Ok(line.into());
				}
				rooms_application::direct::Notice::Ready(reply) => {
					received.borrow_mut().push("directReady".into());
					*reciprocal.borrow_mut() = Some((hosted.borrowed(), reply.clone()));
				}
				rooms_application::direct::Notice::HandRoom { .. } => {
					received.borrow_mut().push("handRoom".into());
				}
				rooms_application::direct::Notice::OfferRoom { .. } => {
					received.borrow_mut().push("offerRoom".into());
				}
				rooms_application::direct::Notice::HandArchive { .. } => {
					received.borrow_mut().push("handArchive".into());
				}
				rooms_application::direct::Notice::OfferArchive { .. } => {
					received.borrow_mut().push("offerArchive".into());
				}
				_ => {}
			}
			Ok(Argument::Void)
		}))
		.unwrap()
}

fn open_managed(
	allow: &Rc<Cell<bool>>,
	published: &Rc<RefCell<Vec<String>>>,
	room_link: &str,
	manager_link: &str,
) -> Result<Argument, String> {
	published.borrow_mut().push("openManaged".into());
	if !allow.get() {
		return Err("managed rooms are unavailable".into());
	}
	let session = glowcap::current_session()
		.map_err(|e| e.to_string())?
		.ok_or("openManaged needs a session")?;
	let room_link = room_link.to_owned();
	let manager_link = manager_link.to_owned();
	let bootstrap = session
		.spawn_owned(move |verb, _| match verb {
			"roomAuthorities" => Ok(Argument::List(vec![
				room_link.clone().into(),
				manager_link.clone().into(),
			])),
			_ => Err("unknown bootstrap method".into()),
		})
		.map_err(|e| e.to_string())?;
	let room = session
		.spawn_owned(|_, _| Err("use the durable managed room link".into()))
		.map_err(|e| e.to_string())?;
	Ok(Argument::List(vec![room.into(), bootstrap.into()]))
}
