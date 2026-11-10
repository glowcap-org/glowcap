//! The Rooms operator capability: the inventories under one revision, the
//! search that cuts them, the acts each row offers, the stewardship verbs,
//! and the watch that tells a holder when anything moved. The policy in
//! `rooms_application::server::operations::operator` decides. This reads the
//! live state into it and performs what it names.
mod acts;
mod batch;

use super::super::{
	authority, history, irc, rooms,
	state::{Shared, State},
};
use glowcap::{Argument, Session, current_session};
use rooms_application::{
	failure::FailureCode,
	room::stewardship::Kind,
	server::{
		document::MAX_DURABLE_ROOM,
		operations::{
			faces,
			journal::Journal,
			operator::{
				self, Category, MAX_PAGE, ResetScope, SnapshotAsk, inventory::View, page, read_snapshot, rows, verbs,
			},
		},
		rooms::Mutation,
	},
};
use rooms_glowcap::Value;

/// The verbs answer through this wire form.
pub(in crate::server) struct Wire;
impl rooms_application::server::operations::listeners::Wire for Wire {
	type Value = Argument;
	fn text(value: &str) -> Argument {
		Argument::String(value.into())
	}
	fn integer(value: u64) -> Argument {
		Argument::Integer(i64::try_from(value).unwrap_or(i64::MAX))
	}
	fn boolean(value: bool) -> Argument {
		Argument::Boolean(value)
	}
	fn null() -> Argument {
		Argument::Void
	}
	fn list(values: Vec<Argument>) -> Argument {
		Argument::List(values)
	}
}

pub(super) fn behavior(shared: Shared) -> impl FnMut(Option<&str>, &[Argument]) -> Result<Argument, String> {
	move |verb, args| {
		let verb = verb.ok_or("direct invocation is not supported")?;
		let session = current_session()
			.map_err(|e| e.to_string())?
			.ok_or("the Rooms operator is reachable only over a session")?;
		if verb != verbs::WATCH && super::carries_capability(args) {
			return Err(format!("Rooms operator {verb} does not take capability arguments"));
		}
		let connection = shared.borrow_mut().admit(session.borrowed());
		let values: Vec<Value<'_>> = rooms_glowcap::values(args).collect();
		match verb {
			verbs::SNAPSHOT => snapshot(&shared, connection, &values),
			verbs::RETIRE_MATCHING => batch::retire_matching(&shared, connection, &values),
			verbs::WATCH => watch(&shared, connection, &session, args),
			verbs::UNWATCH => {
				if !args.is_empty() {
					return Err("unwatch takes no arguments".into());
				}
				let state = shared.borrow();
				let withdrawn = state.operator.borrow_mut().unwatch(connection);
				if let Some(observer) = withdrawn {
					state.give_back(connection, observer);
				}
				Ok(Argument::Void)
			}
			verbs::REVOKE_ROOM_LINK => {
				let name = operator::one_text(&values, "revokeRoomLink takes one room name")?;
				let state = shared.borrow();
				let name = owned_room(&state, &name)?;
				let token = state
					.links
					.swiss(Kind::Room, &name)
					.ok_or_else(|| format!("this server has no room link for \"{name}\""))?
					.to_owned();
				authority::revoke(&state, Kind::Room, token)
			}
			verbs::REVOKE_ROOM_AUTHORITY => {
				let (kind, token) = operator::two_texts(
					&values,
					"revokeRoomAuthority takes a room authority kind and publication token",
				)?;
				let kind = Kind::parse(&kind)
					.ok_or("revokeRoomAuthority takes a room authority kind and publication token")?;
				if kind == Kind::Steward {
					let publication = irc::authority::by_token(&shared.borrow(), &token);
					if let Some(publication) = publication {
						return irc::authority::change(&shared, publication, Some(token), false);
					}
				}
				authority::revoke(&shared.borrow(), kind, token)
			}
			verbs::REVOKE_NICK => {
				let (nick, id) = operator::two_texts(&values, "revokeNick takes a nickname and session id")?;
				let mut state = shared.borrow_mut();
				acts::revoke_nick(&mut state, connection, &nick, &id)?;
				Ok(Argument::Void)
			}
			verbs::DISCONNECT_SESSION => {
				let id = operator::one_text(&values, "disconnectSession takes one session id")?;
				batch::disconnect_session(&shared, connection, id)
			}
			verbs::REMOVE_ROOM => {
				let id = operator::one_text(&values, "removeOperatorRoom takes one room id")?;
				batch::remove_room(&shared, connection, id)
			}
			verbs::RELEASE_REFERENCE => {
				let id = operator::one_text(&values, "releaseOperatorReference takes one reference id")?;
				batch::release_reference(&shared, connection, id)
			}
			verbs::CLEAR_TROUBLE => {
				if !args.is_empty() {
					return Err("clearOperatorTrouble takes no arguments".into());
				}
				let state = shared.borrow();
				if state.journal.borrow_mut().clear() {
					state.changed();
				}
				Ok(Argument::Void)
			}
			verbs::RESET_SCOPE => {
				let scope = operator::one_text(&values, "resetOperatorScope takes one scope")?;
				let scope = ResetScope::parse(&scope).ok_or("unknown operator reset scope")?;
				batch::reset(&shared, connection, scope)
			}
			verbs::GIVE_STEWARD | verbs::ISSUE_MANAGER => {
				let kind = link_kind(verb);
				let name = operator::one_text(&values, "issuing a link takes one durable room name")?;
				let publication = irc::authority::named(&shared.borrow(), &name);
				if let Some(publication) = publication {
					return match kind {
						Kind::Steward => irc::authority::change(&shared, publication, None, true),
						_ => Err(bridge_has_no_manager()),
					};
				}
				let state = shared.borrow();
				let name = owned_room(&state, &name)?;
				issue(&state, kind, name)
			}
			verbs::FORGET_ROOM => {
				let name = operator::one_text(&values, "forgetting a room takes one durable room name")?;
				let state = shared.borrow();
				if irc::authority::named(&state, &name).is_some() {
					return Err(FailureCode::NotSteward
						.line("An IRC room is run by its bridge. Remove the bridge to forget it."));
				}
				let name = owned_room(&state, &name)?;
				forget(&state, name)
			}
			verbs::GIVE_MANAGER => {
				let identity = operator::one_text(&values, "giveManager takes one room management identity")?;
				if identity.is_empty() {
					return Err("giveManager takes one room management identity".into());
				}
				let state = shared.borrow();
				let name = state.manager_name(&identity)?;
				let (held, published) = (name.clone(), name.clone());
				authority::submit(
					&state,
					verbs::GIVE_MANAGER,
					move |state| Ok(state.authority.remembered(&held, false, true, None)?),
					move |state, caller| {
						state.publish_room(&published)?;
						let manager = state.publish_manager(&published)?;
						Ok(state.link_for(&manager, Some(caller))?.into())
					},
				)
			}
			verbs::REVOKE_STEWARD | verbs::REVOKE_MANAGER => {
				let kind = link_kind(verb);
				let name = operator::one_text(&values, "revoking a link takes one durable room name")?;
				let publication = irc::authority::named(&shared.borrow(), &name);
				if let Some(publication) = publication {
					if kind != Kind::Steward {
						return Err(bridge_has_no_manager());
					}
					let token = irc::authority::token(&publication)
						.ok_or_else(|| FailureCode::NotSteward.line("This IRC room has no issued moderator link."))?;
					return irc::authority::change(&shared, publication, Some(token), true);
				}
				let state = shared.borrow();
				let name = owned_room(&state, &name)?;
				revoke(&state, kind, &name)
			}
			_ => Err(format!("Rooms operator has no method {verb}")),
		}
	}
}

/// The link an operator verb issues or revokes.
fn link_kind(verb: &str) -> Kind {
	if verb == verbs::GIVE_STEWARD || verb == verbs::REVOKE_STEWARD {
		Kind::Steward
	} else {
		Kind::Manager
	}
}
fn link_word(kind: Kind) -> &'static str {
	match kind {
		Kind::Room => "room",
		Kind::Steward => "moderator",
		Kind::Manager => "manager",
	}
}
fn bridge_has_no_manager() -> String {
	FailureCode::NotSteward.line("An IRC room is run by its bridge and takes no manager link.")
}

/// Issue `kind`'s link for `name`: a fresh generation when none stands, or
/// the standing one published again when its host publication failed. The
/// room's own link stands with it, because either link governs a room people
/// can enter.
fn issue(state: &State, kind: Kind, name: String) -> Result<Argument, String> {
	let steward = kind == Kind::Steward;
	let verb = if steward {
		verbs::GIVE_STEWARD
	} else {
		verbs::ISSUE_MANAGER
	};
	let (held, published) = (name.clone(), name);
	authority::submit(
		state,
		verb,
		move |state| Ok(state.authority.remembered(&held, steward, !steward, None)?),
		move |state, caller| {
			state.publish_room(&published)?;
			if steward {
				state.publish_steward(&published)?;
			} else {
				state.publish_manager(&published)?;
			}
			stewardship_row(state, &published, caller)
		},
	)
}

/// Revoke `kind`'s standing link for `name`, so every copy stops at once.
fn revoke(state: &State, kind: Kind, name: &str) -> Result<Argument, String> {
	let (verb, held) = match kind {
		Kind::Steward => (verbs::REVOKE_STEWARD, state.authority.has_steward(name)),
		_ => (verbs::REVOKE_MANAGER, state.authority.has_manager(name)),
	};
	if !held {
		return Err(
			FailureCode::NotSteward.line(format_args!("Room \"{name}\" has no issued {} link.", link_word(kind)))
		);
	}
	let token = state
		.links
		.swiss(kind, name)
		.ok_or_else(|| format!("Room \"{name}\" has no published {} link.", link_word(kind)))?
		.to_owned();
	let (prepare, commit) = authority::revocation(kind, token.clone(), None);
	authority::submit(state, verb, prepare, move |state, caller| {
		let name = state.links.resolve(kind, &token)?;
		commit(state)?;
		stewardship_row(state, &name, caller)
	})
}

/// Forget `name` entirely: anyone in the live room is removed, every link
/// the server published for it stops at once, its record goes, and its
/// name is free. The row answers nothing because there is no row left.
fn forget(state: &State, name: String) -> Result<Argument, String> {
	let reserved = history::reserve(state)?;
	let (prepared, committed) = (name.clone(), name);
	authority::submit(
		state,
		verbs::FORGET_ROOM,
		move |state| Ok(state.authority.with_room_forgotten(&prepared)?),
		move |state, _| {
			let name = committed;
			// The history slot was reserved before the authority was saved, so
			// the live room and the lines kept under its key go with no
			// fallible step left between them and the saved authority.
			let key = match faces::live_room(&state.rooms, &name) {
				Some(live) => live.key.clone(),
				None => rooms::durable_key(&name),
			};
			history::mutate_reserved(state, reserved, |rooms| {
				let effects = rooms.retire_room(&key, acts::ROOM_REMOVED);
				let persist = rooms.forget_history(&key);
				Ok(((), Mutation { effects, persist }))
			})?;
			for kind in [Kind::Room, Kind::Steward, Kind::Manager] {
				if let Some(token) = state.unpublish(kind, &name) {
					state.authority_ended(&name, kind, &token);
				}
			}
			Ok(Argument::Void)
		},
	)
}

/// The durable name an operator verb acts on: a live room's, or one this
/// server holds a link or record under, matched the way links fold names.
/// The room list reads the same set, so every row it shows can be acted on.
fn owned_room(state: &State, asked: &str) -> Result<String, String> {
	if asked.is_empty() || asked.chars().count() > MAX_DURABLE_ROOM {
		return Err(FailureCode::NoSuchRoom.line(format_args!("A room name is 1 to {MAX_DURABLE_ROOM} characters.")));
	}
	faces::owned_name(&state.rooms, &state.authority, asked)
		.ok_or_else(|| FailureCode::NoSuchRoom.line(format_args!("This server owns no room named \"{asked}\".")))
}

/// The row `name` answers after a change, listed or not: revoking the last
/// link of a room nobody is in answers a row with no link and no place in
/// the inventory.
fn stewardship_row(state: &State, name: &str, caller: &Session) -> Result<Argument, String> {
	let row = faces::stewardship_row(
		&state.rooms,
		&state.authority,
		|kind, name| state.held_link(kind, name, Some(caller)),
		name,
	);
	Ok(rows::wire_stewardship::<Wire>(&row))
}

/// The inventories' view of the live state, for `connection`'s read.
/// `journal` is the caller's borrow of the state's ring.
fn view<'a>(state: &'a State, journal: &'a Journal, connection: u64) -> Result<View<'a, u64, glowcap::Ref>, String> {
	Ok(View {
		rooms: &state.rooms,
		directory: &state.policy,
		authority: &state.authority,
		sessions: state
			.session_faces()
			.map(|face| operator::inventory::SessionRow {
				id: face.id,
				transport: face.transport,
				nick: face.nick,
				connection: face.connection,
			})
			.collect(),
		caller: connection,
		journal,
		foreign: super::peering::faces(state),
		irc: irc::operator::faces(state)?,
	})
}

/// One category's sources, read fresh.
fn sources(
	state: &State,
	connection: u64,
	category: Category,
	kind: Option<operator::ReferenceKind>,
) -> Result<Vec<page::Source<rows::Row, operator::inventory::Act>>, String> {
	let journal = state.journal.borrow();
	Ok(view(state, &journal, connection)?.sources(category, kind, &|link, name| state.held_link(link, name, None)))
}

fn page_of(
	view: &View<'_, u64, glowcap::Ref>,
	state: &State,
	category: Category,
	ask: (u64, u64, &str, Option<operator::ReferenceKind>),
) -> page::Page<rows::Row> {
	let (cursor, limit, query, kind) = ask;
	page::query_page(
		view.sources(category, kind, &|link, name| state.held_link(link, name, None))
			.into_iter(),
		query,
		cursor,
		limit,
	)
}

fn snapshot(shared: &Shared, connection: u64, values: &[Value<'_>]) -> Result<Argument, String> {
	let state = shared.borrow();
	let ask = read_snapshot(values)?;
	let journal = state.journal.borrow();
	let view = view(&state, &journal, connection)?;
	let revision = state.operator.borrow().current();
	match ask {
		SnapshotAsk::Whole { query, kind } => {
			let pages = operator::whole_pages(&query, kind, |category, query, kind| {
				page_of(&view, &state, category, (0, MAX_PAGE, query, kind))
			});
			Ok(rows::wire_whole::<Wire>(revision, &pages))
		}
		SnapshotAsk::Page {
			category,
			cursor,
			limit,
			query,
			kind,
		} => {
			let page = page_of(&view, &state, category, (cursor, limit, &query, kind));
			Ok(rows::wire_page::<Wire>(revision, &page))
		}
	}
}

/// Admit a watcher: it hears the current revision at once, and every move
/// after. A word that cannot be queued during admission ends it.
fn watch(shared: &Shared, connection: u64, session: &Session, args: &[Argument]) -> Result<Argument, String> {
	let [Argument::Reference(observer)] = args else {
		return Err("watch takes one callback capability".into());
	};
	let state = shared.borrow();
	let replaced = state
		.operator
		.borrow_mut()
		.watch(connection, observer.clone())
		.inspect_err(|_| state.give_back(connection, observer.clone()))?;
	if let Some(replaced) = replaced {
		state.give_back(connection, replaced);
	}
	let revision = state.operator.borrow().current();
	if session
		.tell(observer, verbs::CHANGED, &[Argument::Integer(revision as i64)])
		.is_err()
	{
		if let Some(observer) = state.operator.borrow_mut().unwatch(connection) {
			state.give_back(connection, observer);
		}
		return Err("the Rooms operator watch ended during admission".into());
	}
	Ok(Argument::Integer(revision as i64))
}
