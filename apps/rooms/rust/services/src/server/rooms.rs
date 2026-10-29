//! The room object a member holds: what one may ask of the room they are
//! in, or about to be in. One membership per connection, so nothing here
//! takes a "from": the calling session names the caller, because a room
//! reference crosses connections through a handoff or a link.
use super::{
	authority, files, lines, seat,
	state::{Shared, State},
};
use glowcap::{Argument, Ref, current_session};
use rooms_application::{
	directory::{creation::RecoveryKey, registration::Id},
	failure::FailureCode,
	room::{
		ArgumentView,
		authority::{LINK, MANAGED_IDENTITY},
		membership::SUBSCRIBE,
		queries::{CALLED, POLICY, PRIVATE},
	},
	server::{
		directory::NAME_VOUCHER_BYTES,
		rooms::{Entrance, Fresh, Gate, Open, Refusal, RoomKey},
	},
};
use rooms_glowcap::Value;
use std::{cell::Cell, rc::Rc};
mod public_membership;
mod publication_link;
pub(super) use public_membership::subscribe_publication;
pub(super) use publication_link::link_publication;

/// The key a durable name's room lives under.
pub(super) fn durable_key(name: &str) -> RoomKey {
	if RecoveryKey::accepts(name) {
		RoomKey::managed(name)
	} else {
		RoomKey::public(name)
	}
}

/// Fresh identities for a room the verb may create.
pub(super) fn fresh(state: &State) -> Result<Fresh, String> {
	let mut bytes = [0u8; 16];
	for _ in 0..8 {
		rooms_platform::entropy::fill(&mut bytes).map_err(|e| format!("drawing a room identity failed: {e}"))?;
		let entry_id = Id::from_entropy(bytes);
		if state.rooms.entry_id_known(&entry_id) || state.authority.publication_room(entry_id.as_str()).is_some() {
			continue;
		}
		rooms_platform::entropy::fill(&mut bytes).map_err(|e| format!("drawing a room key failed: {e}"))?;
		return Ok(Fresh {
			entry_id,
			private_key: RecoveryKey::from_entropy(bytes),
		});
	}
	Err("room identities are exhausted".into())
}

/// The calling session's connection, for a reference that may have crossed
/// connections.
pub(super) fn caller(state: &mut State) -> Result<(u64, glowcap::Session), String> {
	let session = current_session()
		.map_err(|e| e.to_string())?
		.ok_or("a room is reachable only over a session")?;
	let connection = state.admit(session.borrowed());
	Ok((connection, session))
}

fn refusal(refusal: Refusal) -> String {
	refusal.reason()
}

/// The behavior of one room entrance reference. `subscribe` creates the live
/// room when needed and seats the caller. The other verbs describe the room
/// the entrance names.
pub(super) fn entrance(
	shared: Shared,
	entrance: Entrance,
) -> impl FnMut(Option<&str>, &[Argument]) -> Result<Argument, String> {
	move |verb, args| {
		let verb = verb.ok_or("direct invocation is not supported")?;
		if verb != SUBSCRIBE && args.iter().any(|arg| Value(arg).contains_capability()) {
			return Err(format!("room {verb} does not take capability arguments"));
		}
		let mut state = shared.borrow_mut();
		let (connection, session) = caller(&mut state)?;
		state.ingress(connection)?;
		if !state.rooms.gate_open(connection, &entrance, &state.authority) {
			let detail = match entrance.gate {
				Gate::Link { .. } => "this room link was revoked",
				_ => "this room entrance is no longer offered",
			};
			return Err(FailureCode::NoSuchRoom.line(format_args!("{detail}")));
		}
		if verb != SUBSCRIBE {
			state.admit_work(connection, rooms_application::admission::Class::Read, 1)?;
		}
		match verb {
			SUBSCRIBE => subscribe(&shared, &mut state, connection, &session, &entrance, args),
			CALLED => {
				if !args.is_empty() {
					return Err("called takes no arguments".into());
				}
				Ok(state.rooms.called(&entrance, &state.authority).into())
			}
			PRIVATE => {
				if !args.is_empty() {
					return Err("private takes no arguments".into());
				}
				let listed = state.rooms.policy(&entrance, &state.authority).is_listed();
				Ok(if listed { "listed" } else { "private" }.into())
			}
			POLICY => {
				if !args.is_empty() {
					return Err("roomPolicy takes no arguments".into());
				}
				let modes = state.rooms.policy(&entrance, &state.authority).modes();
				Ok(Argument::List(modes.iter().map(|mode| (*mode).into()).collect()))
			}
			MANAGED_IDENTITY => {
				if !args.is_empty() {
					return Err("managedRoomIdentity takes no arguments".into());
				}
				let durable = durable_name(&state, &entrance);
				let identity = state.authority.manager_identity(&durable);
				state.links.cache_identity(&durable, identity.clone())?;
				Ok(identity.into())
			}
			LINK => {
				if !args.is_empty() {
					return Err("link takes no arguments".into());
				}
				let durable = durable_name(&state, &entrance);
				state
					.current_room_link(&durable)
					.map(Argument::String)
					.ok_or_else(|| "this room has no link; a room manager must create one".into())
			}
			_ => Err(format!("room has no method {verb}")),
		}
	}
}

fn durable_name(state: &State, entrance: &Entrance) -> String {
	state
		.rooms
		.durable_name(&entrance.room)
		.map(String::from)
		.or_else(|| entrance.durable.clone())
		.unwrap_or_else(|| entrance.room.as_str().to_owned())
}

fn subscribe(
	shared: &Shared,
	state: &mut State,
	connection: u64,
	session: &glowcap::Session,
	entrance: &Entrance,
	args: &[Argument],
) -> Result<Argument, String> {
	let shape =
		|| format!("subscribe needs an inbox capability, a name, and optional {NAME_VOUCHER_BYTES}-byte name voucher");
	let voucher = match args.len() {
		2 => None,
		3 => match args[2].as_bytes() {
			Some(bytes) if bytes.len() == NAME_VOUCHER_BYTES => {
				let mut voucher = [0u8; NAME_VOUCHER_BYTES];
				voucher.copy_from_slice(bytes);
				Some(voucher)
			}
			_ => return Err(shape()),
		},
		_ => return Err(shape()),
	};
	let (Some(nick), Some(Argument::Reference(inbox))) = (args[0].as_str(), args.get(1)) else {
		return Err(shape());
	};
	if Value(&args[0]).contains_capability() {
		return Err(shape());
	}
	let fresh = fresh(state)?;
	let generation: [u8; 36] = state
		.rooms
		.generation(&entrance.room)
		.unwrap_or(fresh.entry_id.as_str())
		.as_bytes()
		.try_into()
		.map_err(|_| "room generation is not a canonical identifier")?;
	state.admit_join(
		connection,
		core::str::from_utf8(&generation).map_err(|_| "room generation is not text")?,
	)?;
	// The actors this seat is answered with are minted before the seat is
	// filed; a refusal drops them unfilled and nothing is orphaned.
	let membership = Rc::new(Cell::new(None));
	let seat = session
		.spawn_owned(seat::seat(shared.clone(), entrance.room.clone(), membership.clone()))
		.map_err(|e| e.to_string())?;
	// A participant is handed the subject facet and the files facet; an
	// observer holds neither, and a client draws its controls from what it
	// holds rather than from the seat's word about itself.
	let (subject, files) = match entrance.kind {
		rooms_application::room::policy::MembershipKind::Participant => (
			Some(
				session
					.spawn_owned(lines::subject(shared.clone(), entrance.room.clone()))
					.map_err(|e| e.to_string())?,
			),
			Some(
				session
					.spawn_owned(files::facet(shared.clone(), entrance.room.clone(), membership.clone()))
					.map_err(|e| e.to_string())?,
			),
		),
		rooms_application::room::policy::MembershipKind::Observer => (None, None),
	};
	let authority = state.authority.clone();
	let claimants = state.claimants();
	let same = |a: u64, b: u64| {
		a == b
			|| matches!(
				(claimants.get(&a), claimants.get(&b)),
				(Some(Some(left)), Some(Some(right))) if left == right
			)
	};
	let State { rooms, policy, .. } = state;
	let seated = rooms
		.subscribe(
			connection,
			entrance,
			nick,
			inbox.clone(),
			voucher,
			seat.clone(),
			subject.clone(),
			policy,
			same,
			&authority,
			Some(fresh),
		)
		.map_err(|refused| refusal(refused.refusal))?;
	membership.set(Some(seated.membership));
	state.apply_rooms(seated.effects);
	Ok(Argument::List(vec![
		Argument::Reference(seat),
		seated.kind.as_str().into(),
		subject.map(Argument::Reference).unwrap_or(Argument::Void),
		files.map(Argument::Reference).unwrap_or(Argument::Void),
	]))
}

/// `open`, `openManaged`, `enter`, `enterPublication`, `link`, and
/// `openPrivateLink` on the directory root.
pub(super) fn directory_verb(
	shared: &Shared,
	connection: u64,
	verb: &str,
	args: &[Argument],
) -> Result<Argument, String> {
	use rooms_application::directory::creation;
	let mut state = shared.borrow_mut();
	let text = |at: usize| args.get(at).and_then(Argument::as_str);
	match verb {
		creation::OPEN | creation::OPEN_MANAGED => {
			let managed = verb == creation::OPEN_MANAGED;
			let (name, policy, recovery) = if managed {
				let modes = [text(1), text(2), text(3)];
				let (Some(name), [Some(v), Some(e), Some(s)], Some(key), 5) = (text(0), modes, text(4), args.len())
				else {
					return Err("openManaged needs a room name, three policy modes, and opaque room id".into());
				};
				let policy = rooms_application::room::policy::RoomPolicy::parse(&[v, e, s])
					.ok_or("openManaged names no supported room access state")?;
				if !RecoveryKey::accepts(key) {
					return Err("openManaged needs a room name, three policy modes, and opaque room id".into());
				}
				(name, policy, Some(key))
			} else {
				let private = args.get(1).and_then(Argument::as_bool);
				let shape = || "open needs a room name, optional private flag, and optional recovery key".to_string();
				if args.is_empty() || args.len() > 3 || text(0).is_none() {
					return Err(shape());
				}
				if args.len() >= 2 && private.is_none() {
					return Err(shape());
				}
				let recovery = if args.len() == 3 {
					if private != Some(true) {
						return Err(shape());
					}
					Some(text(2).ok_or_else(shape)?)
				} else {
					None
				};
				let policy = if private == Some(true) {
					rooms_application::room::policy::RoomPolicy::Private
				} else {
					rooms_application::room::policy::RoomPolicy::Open
				};
				(text(0).unwrap_or(""), policy, recovery)
			};
			if policy.is_listed()
				&& (state.foreign.holds_name(name)
					|| state.irc.holds_name(name)
					|| state.authority_writer.holds_name(name))
			{
				return Err(FailureCode::RoomExists.line(format_args!("room \"{name}\" already exists")));
			}
			let fresh = fresh(&state)?;
			let authority = state.authority.clone();
			let opening = state
				.rooms
				.open(
					connection,
					Open {
						name,
						policy,
						recovery,
						managed,
					},
					fresh,
					&authority,
				)
				.map_err(refusal)?;
			let session = state
				.session(connection)
				.ok_or("a room is reachable only over a session")?;
			let room = session
				.spawn_owned(entrance(shared.clone(), opening.entrance))
				.map_err(|e| e.to_string())?;
			match opening.bootstrap {
				None => Ok(Argument::Reference(room)),
				Some(bootstrap) => {
					let bootstrap = session
						.spawn_owned(authority::bootstrap(shared.clone(), bootstrap.name, bootstrap.managed))
						.map_err(|e| e.to_string())?;
					Ok(Argument::List(vec![
						Argument::Reference(room),
						Argument::Reference(bootstrap),
					]))
				}
			}
		}
		creation::ENTER | creation::ENTER_PUBLICATION => {
			let (Some(name), 1) = (text(0), args.len()) else {
				return Err(if verb == creation::ENTER {
					"enter needs one room name"
				} else {
					"enterPublication needs one publication id"
				}
				.into());
			};
			let irc = {
				let core = state.irc.core.borrow();
				let bridge = if verb == creation::ENTER {
					core.by_room_name(name)
				} else {
					core.by_publication(name)
				};
				bridge
					.and_then(|(key, _)| state.irc.publications.get(key))
					.filter(|publication| publication.active.get())
					.cloned()
			};
			if let Some(publication) = irc {
				let session = state
					.session(connection)
					.ok_or("a room is reachable only over a session")?;
				return session
					.spawn_owned(super::irc::rooms::entrance(
						shared.clone(),
						publication,
						rooms_application::room::policy::MembershipKind::Participant,
					))
					.map(Argument::Reference)
					.map_err(|e| e.to_string());
			}
			// A foreign room is handed straight through: the capability its
			// source published, never a proxy through this process.
			let foreign = if verb == creation::ENTER {
				state.foreign.by_name(name)
			} else {
				state.foreign.by_id(name).filter(|entry| entry.is_live())
			};
			if let Some(room) = foreign.and_then(|entry| entry.room.clone()) {
				return Ok(Argument::Reference(room));
			}
			let found = if verb == creation::ENTER {
				state.rooms.enter(name, &state.authority)
			} else {
				state.rooms.enter_publication(name, &state.authority)
			}
			.map_err(refusal)?;
			let session = state
				.session(connection)
				.ok_or("a room is reachable only over a session")?;
			Ok(Argument::Reference(
				session
					.spawn_owned(entrance(shared.clone(), found))
					.map_err(|e| e.to_string())?,
			))
		}
		creation::LINK => {
			let (Some(name), 1) = (text(0), args.len()) else {
				return Err(format!(
					"link needs one room name of at most {} characters",
					rooms_application::server::rooms::MAX_ROOM
				));
			};
			if name.is_empty() || name.encode_utf16().count() > rooms_application::server::rooms::MAX_ROOM {
				return Err(format!(
					"link needs one room name of at most {} characters",
					rooms_application::server::rooms::MAX_ROOM
				));
			}
			if let Some((key, _)) = state.irc.core.borrow().by_room_name(name) {
				let publication = state.irc.publications.get(key).ok_or("IRC room is not published")?;
				return state
					.link(
						publication
							.swiss
							.borrow()
							.as_deref()
							.ok_or("IRC room is not published")?,
					)
					.map(Argument::from);
			}
			if state.foreign.holds_name(name) {
				return Err("a foreign room is linked by its source directory".into());
			}
			let Some(key) = state.rooms.public_key_of(name) else {
				return Err(FailureCode::NoSuchRoom.line(format_args!("no room named \"{name}\"")));
			};
			let durable = state
				.rooms
				.durable_name(&key)
				.map(String::from)
				.unwrap_or_else(|| name.into());
			authority::link(&state, durable)
		}
		creation::PRIVATE_LINK => {
			let (Some(key), 1) = (text(0), args.len()) else {
				return Err("openPrivateLink needs one opaque private room key".into());
			};
			if !RecoveryKey::accepts(key) {
				return Err("openPrivateLink needs one opaque private room key".into());
			}
			authority::link(&state, key.into())
		}
		_ => Err(format!("directory has no method {verb}")),
	}
}

/// The claim-invitation entrance: the invitation actor is the claimant's.
pub(super) fn invitation_entrance(
	shared: &Shared,
	session: &glowcap::Session,
	entrance: Entrance,
) -> Result<Ref, String> {
	session
		.spawn_owned(self::entrance(shared.clone(), entrance))
		.map_err(|e| e.to_string())
}
