//! The Rooms operator capability: the inventories under one revision, the
//! search that cuts them, the acts each row offers, the stewardship verbs,
//! and the watch that tells a holder when anything moved. The policy in
//! `rooms_application::server::operations::operator` decides. This reads the
//! live state into it and performs what it names.
mod acts;
mod batch;

use super::super::{
	authority, irc,
	state::{Shared, State},
};
use glowcap::{Argument, Session, current_session};
use rooms_application::{
	failure::FailureCode,
	room::stewardship::Kind,
	server::{
		document::MAX_DURABLE_ROOM,
		operations::{
			faces::stewardship_rows,
			journal::Journal,
			operator::{
				self, Category, MAX_PAGE, ResetScope, SnapshotAsk, inventory::View, page, read_snapshot, rows, verbs,
			},
		},
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

pub(super) fn behavior(shared: Shared) -> impl FnMut(&str, &[Argument]) -> Result<Argument, String> {
	move |verb, args| {
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
				let name = named_room(&state, &name)?;
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
				let kind = match kind.as_str() {
					"room" => Kind::Room,
					"steward" => Kind::Steward,
					"manager" => Kind::Manager,
					_ => return Err("revokeRoomAuthority takes a room authority kind and publication token".into()),
				};
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
				acts::revoke_nick(&mut state, &nick, &id)?;
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
			verbs::GIVE_STEWARD => {
				let name = operator::one_text(&values, "giveSteward takes one durable room name")?;
				let publication = irc::authority::named(&shared.borrow(), &name);
				if let Some(publication) = publication {
					return irc::authority::change(&shared, publication, None, true);
				}
				let state = shared.borrow();
				let name = named_room(&state, &name)?;
				let (held, published) = (name.clone(), name.clone());
				authority::submit(
					&state,
					"giveSteward",
					move |state| Ok(state.authority.remembered(&held, true, false, None)?),
					move |state, caller| {
						state.publish_room(&published)?;
						state.publish_steward(&published)?;
						stewardship_row(state, &published, caller)
					},
				)
			}
			verbs::GIVE_MANAGER => {
				let identity = operator::one_text(&values, "giveManager takes one room management identity")?;
				if identity.is_empty() {
					return Err("giveManager takes one room management identity".into());
				}
				let state = shared.borrow();
				let name = state.links.manager_name(&identity)?.to_owned();
				let (held, published) = (name.clone(), name.clone());
				authority::submit(
					&state,
					"giveManager",
					move |state| Ok(state.authority.remembered(&held, false, true, None)?),
					move |state, caller| {
						state.publish_room(&published)?;
						let manager = state.publish_manager(&published)?;
						Ok(state.link_for(&manager, Some(caller))?.into())
					},
				)
			}
			verbs::REVOKE_STEWARD => {
				let name = operator::one_text(&values, "revokeSteward takes one durable room name")?;
				let publication = irc::authority::named(&shared.borrow(), &name);
				if let Some(publication) = publication {
					let token = irc::authority::token(&publication).ok_or_else(|| {
						FailureCode::NotSteward.line("this IRC room has no issued moderator capability")
					})?;
					return irc::authority::change(&shared, publication, Some(token), true);
				}
				let state = shared.borrow();
				let name = named_room(&state, &name)?;
				if !state.authority.has_steward(&name) {
					return Err(FailureCode::NotSteward
						.line(format_args!("Room \"{name}\" has no issued moderator capability.")));
				}
				let token = state
					.links
					.swiss(Kind::Steward, &name)
					.ok_or_else(|| format!("Room \"{name}\" has no published moderator capability."))?
					.to_owned();
				let held = token.clone();
				authority::submit(
					&state,
					"revokeSteward",
					move |state| {
						let name = state.links.resolve(Kind::Steward, &held)?;
						Ok(Some(state.authority.with_steward_revoked(&name)?.0))
					},
					move |state, caller| {
						let name = state.links.resolve(Kind::Steward, &token)?;
						state.unpublish(Kind::Steward, &name);
						state.authority_ended(&name, Kind::Steward, &token);
						stewardship_row(state, &name, caller)
					},
				)
			}
			_ => Err(format!("Rooms operator has no method {verb}")),
		}
	}
}

/// The durable name the operator verbs act on: a live room's, or one this
/// server made durable, matched without regard to case.
fn named_room(state: &State, asked: &str) -> Result<String, String> {
	if asked.is_empty() || asked.chars().count() > MAX_DURABLE_ROOM {
		return Err(FailureCode::NoSuchRoom.line("A moderator capability needs a durable room name."));
	}
	if let Some(live) = rooms_application::server::operations::faces::live_room(&state.rooms, asked) {
		return Ok(live.durable_name.to_owned());
	}
	state
		.authority
		.linked_rooms()
		.find(|name| name.eq_ignore_ascii_case(asked))
		.map(String::from)
		.ok_or_else(|| FailureCode::NoSuchRoom.line(format_args!("This server owns no room named \"{asked}\".")))
}

fn stewardship_row(state: &State, name: &str, caller: &Session) -> Result<Argument, String> {
	stewardship_rows(&state.rooms, &state.authority, |name| {
		state.steward_link_for(name, Some(caller))
	})
	.into_iter()
	.find(|row| row.name.eq_ignore_ascii_case(name))
	.map(|row| rows::wire_stewardship::<Wire>(&row))
	.ok_or_else(|| format!("the stewardship of \"{name}\" disappeared while answering"))
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
	Ok(view(state, &journal, connection)?.sources(category, kind, &|name| state.steward_link(name)))
}

fn page_of(
	view: &View<'_, u64, glowcap::Ref>,
	state: &State,
	category: Category,
	ask: (u64, u64, &str, Option<operator::ReferenceKind>),
) -> page::Page<rows::Row> {
	let (cursor, limit, query, kind) = ask;
	page::query_page(
		view.sources(category, kind, &|name| state.steward_link(name))
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
