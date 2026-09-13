//! Member capabilities hold one exact Rooms seat. IRC identities are shared
//! across that member's channels on a network, and sockets remain host.
use super::*;
use crate::irc::member::Membership;
mod identity;
pub(super) use identity::Identity;
const POST: &str = rooms_application::protocol_data::POST;
const KIND: &str = rooms_application::protocol_data::MEMBERSHIP_KIND;
use glowcap::Argument;
use rooms_application::{
	bridge,
	room::{
		membership::{AWAY, LEAVE},
		policy::MembershipKind,
	},
	server::irc::seat::{self, Phase},
};

struct Lease {
	identity: Rc<Identity>,
	channel: Membership,
}
pub(super) struct Seat {
	pub(super) id: u64,
	connection: u64,
	kind: MembershipKind,
	active: Cell<bool>,
	ended: tokio::sync::watch::Sender<bool>,
	channel: RefCell<Option<Rc<Lease>>>,
}
impl Seat {
	pub fn new(id: u64, connection: u64, kind: MembershipKind) -> Self {
		Self {
			id,
			connection,
			kind,
			active: Cell::new(true),
			ended: tokio::sync::watch::channel(false).0,
			channel: RefCell::new(None),
		}
	}
	fn end(&self) {
		self.active.set(false);
		self.ended.send_replace(true);
	}
}
fn valid(state: &State, publication: &Publication, seat: &Rc<Seat>) -> Result<(), String> {
	if !publication.active.get() || state.irc.stopping {
		return Err(retired());
	}
	if !seat.active.get()
		|| !publication
			.seats
			.borrow()
			.get(&seat.connection)
			.is_some_and(|held| Rc::ptr_eq(held, seat))
	{
		return Err(format!(
			"{}: this IRC bridge membership has ended",
			rooms_application::failure::FailureCode::NotRoomMember.wire()
		));
	}
	Ok(())
}
fn identity_current(state: &State, identity: &Rc<Identity>) -> bool {
	state
		.irc
		.identities
		.get(&(identity.connection, identity.network.clone()))
		.is_some_and(|held| Rc::ptr_eq(held, identity))
}
pub(super) fn show(state: &State, publication: &Publication, connection: u64) {
	let effects = {
		let core = state.irc.core.borrow();
		let (Some(bridge), Some(view)) = (core.bridge(&publication.key), core.view(&publication.key, connection))
		else {
			return;
		};
		bridge.room.seat_changed(connection, view)
	};
	if let Err(reason) = apply(state, &publication.key, effects) {
		trouble(state, "IRC seat update", reason);
	}
}
fn phase(state: &State, publication: &Publication, connection: u64, phase: Phase, nick: Option<&str>) {
	if state
		.irc
		.core
		.borrow_mut()
		.show_seat(&publication.key, connection, phase, nick)
	{
		show(state, publication, connection);
	}
}
pub(super) fn retire(state: &mut State, publication: &Publication, connection: u64, ended: Option<&str>) {
	let Some(seat) = publication.seats.borrow_mut().remove(&connection) else {
		return;
	};
	seat.end();
	retire_speaker(state, publication, &seat);
	let effects = state
		.irc
		.core
		.borrow_mut()
		.bridge_mut(&publication.key)
		.map(|bridge| bridge.room.retire(connection, ended));
	if let Some(effects) = effects
		&& let Err(reason) = apply(state, &publication.key, effects)
	{
		trouble(state, "retiring an IRC seat", reason);
	}
}
fn retire_speaker(state: &mut State, publication: &Publication, seat: &Seat) {
	if let Some(lease) = seat.channel.borrow_mut().take()
		&& let Err(reason) = lease.channel.part()
	{
		trouble(state, "parting an IRC member", reason);
	}
	let core = state.irc.core.clone();
	let network = core
		.borrow()
		.bridge(&publication.key)
		.map(|bridge| bridge.network.clone());
	let last = core.borrow_mut().retire_seat(&publication.key, seat.connection);
	if last == Some(true)
		&& let Some(network) = network
		&& let Some(identity) = state.irc.identities.remove(&(seat.connection, network))
	{
		identity.member.stop();
	}
}
/// Replace only capability custody when speaking authority continues. Reader
/// replacement has already committed synchronously in the portable room.
pub(super) fn replace(state: &mut State, publication: &Rc<Publication>, seat: &Rc<Seat>) {
	let old = publication.seats.borrow_mut().insert(seat.connection, seat.clone());
	let Some(old) = old else { return };
	old.end();
	if old.kind == MembershipKind::Participant && seat.kind == MembershipKind::Participant {
		if let Some(lease) = old.channel.borrow_mut().take() {
			*seat.channel.borrow_mut() = Some(lease.clone());
			watch_lease(state, publication.clone(), seat.clone(), lease);
		}
	} else {
		retire_speaker(state, publication, &old);
	}
}
pub(super) fn start(state: &mut State, publication: Rc<Publication>, seat: Rc<Seat>) {
	let shared = state.shared();
	let mut ended = seat.ended.subscribe();
	state.irc.tasks.spawn_local(async move {
		let outcome = tokio::select! {
			biased;
			_ = ended.changed() => return,
			outcome = membership(&shared, &publication, &seat) => outcome,
		};
		if let Err(reason) = outcome {
			let state = shared.borrow();
			if valid(&state, &publication, &seat).is_ok() {
				let effects = state
					.irc
					.core
					.borrow()
					.bridge(&publication.key)
					.map(|bridge| bridge.room.note_to(seat.connection, &reason));
				if let Some(effects) = effects
					&& let Err(reason) = apply(&state, &publication.key, effects)
				{
					trouble(&state, "reporting IRC membership failure", reason);
				}
			}
		}
	});
}
async fn membership(shared: &Shared, publication: &Rc<Publication>, seat: &Rc<Seat>) -> Result<Membership, String> {
	let identity = identity::ensure(shared, publication, seat).await?;
	join_on(shared, publication, seat, identity).await
}
async fn join_on(
	shared: &Shared,
	publication: &Rc<Publication>,
	seat: &Rc<Seat>,
	identity: Rc<Identity>,
) -> Result<Membership, String> {
	let result = join_current(shared, publication, seat, identity.clone()).await;
	if result.is_err() {
		let state = shared.borrow();
		if valid(&state, publication, seat).is_ok() && identity_current(&state, &identity) {
			phase(&state, publication, seat.connection, Phase::Failed, None);
		}
	}
	result
}
async fn join_current(
	shared: &Shared,
	publication: &Rc<Publication>,
	seat: &Rc<Seat>,
	identity: Rc<Identity>,
) -> Result<Membership, String> {
	{
		let state = shared.borrow();
		valid(&state, publication, seat)?;
		state
			.irc
			.core
			.borrow()
			.speaker_fits(&publication.key, seat.connection)
			.map_err(|e| e.reason())?;
		if seat.channel.borrow().is_none() {
			phase(&state, publication, seat.connection, Phase::Connecting, None);
		}
	}
	let nick = identity.member.ready().await?;
	let lease = {
		let mut state = shared.borrow_mut();
		valid(&state, publication, seat)?;
		if !identity_current(&state, &identity) {
			return Err("the IRC identity was replaced".into());
		}
		let existing = seat
			.channel
			.borrow()
			.clone()
			.filter(|lease| Rc::ptr_eq(&lease.identity, &identity));
		match existing {
			Some(lease) => lease,
			None => {
				let channel = {
					let core = state.irc.core.borrow();
					identity
						.member
						.join(core.bridge(&publication.key).ok_or_else(retired)?.room.channel())?
				};
				let lease = Rc::new(Lease {
					identity: identity.clone(),
					channel,
				});
				*seat.channel.borrow_mut() = Some(lease.clone());
				watch_lease(&mut state, publication.clone(), seat.clone(), lease.clone());
				lease
			}
		}
	};
	lease.channel.ready().await?;
	{
		let state = shared.borrow();
		valid(&state, publication, seat)?;
		if !identity_current(&state, &identity) {
			return Err("the IRC identity was replaced".into());
		}
		phase(&state, publication, seat.connection, Phase::Linked, Some(&nick));
	}
	Ok(lease.channel.clone())
}

fn watch_lease(state: &mut State, publication: Rc<Publication>, seat: Rc<Seat>, held: Rc<Lease>) {
	let shared = state.shared();
	let mut ended = seat.ended.subscribe();
	state.irc.tasks.spawn_local(async move {
		tokio::select! {
			biased;
			_ = ended.changed() => return,
			_ = held.channel.down() => {},
		}
		let state = shared.borrow();
		if valid(&state, &publication, &seat).is_ok()
			&& seat
				.channel
				.borrow()
				.as_ref()
				.is_some_and(|current| Rc::ptr_eq(current, &held))
		{
			seat.channel.borrow_mut().take();
		}
	});
}

pub(super) fn behavior(
	shared: Shared,
	publication: Rc<Publication>,
	seat: Rc<Seat>,
) -> impl FnMut(&str, &[Argument]) -> Result<Argument, String> {
	move |verb, args| {
		if super::super::operations::carries_capability(args) {
			return Err(format!("IRC membership {verb} does not take capabilities"));
		}
		valid(&shared.borrow(), &publication, &seat)?;
		match verb {
			rooms_application::room::invitation::MINT => invitation::mint(&shared, &publication, seat.kind, args),
			KIND if args.is_empty() => Ok(seat.kind.as_str().into()),
			LEAVE if args.is_empty() => {
				retire(&mut shared.borrow_mut(), &publication, seat.connection, None);
				Ok(Argument::Void)
			}
			AWAY => {
				let [Argument::String(why)] = args else {
					return Err("away needs one reason".into());
				};
				let state = shared.borrow();
				let effects = state
					.irc
					.core
					.borrow_mut()
					.bridge_mut(&publication.key)
					.ok_or_else(retired)?
					.room
					.away(seat.connection, why)
					.map_err(|e| e.reason())?;
				apply(&state, &publication.key, effects)?;
				Ok(Argument::Void)
			}
			POST => {
				let [Argument::String(text)] = args else {
					return Err("an IRC bridge post needs exactly one text line".into());
				};
				// Bound before copying into an asynchronous command; IRC cannot
				// carry a payload larger than its entire line limit.
				if text.len() > 512 {
					return Err("this IRC post exceeds the line limit".into());
				}
				let state = shared.borrow();
				let post = state
					.irc
					.core
					.borrow_mut()
					.bridge_mut(&publication.key)
					.ok_or_else(retired)?
					.room
					.prepare_post(seat.connection, text)
					.map_err(|e| e.reason())?;
				let (shared, publication, seat) = (shared.clone(), publication.clone(), seat.clone());
				super::super::answer::later(&state, POST, async move {
					let channel = membership(&shared, &publication, &seat).await?;
					let receipt = if let Some(action) = post.text.strip_prefix("/me ") {
						channel.action(action)?
					} else {
						channel.say(&post.text)?
					};
					receipt
						.wait()
						.await
						.map_err(|e| format!("IRC delivery {:?}: {}", e.delivery, e.reason))?;
					let state = shared.borrow();
					if publication.active.get() {
						let effects = state
							.irc
							.core
							.borrow()
							.bridge(&publication.key)
							.ok_or_else(retired)?
							.room
							.commit_post(&post);
						apply(&state, &publication.key, effects)?;
					}
					Ok(Argument::Void)
				})
			}
			bridge::SUBMIT => {
				if seat.kind != MembershipKind::Participant {
					return Err(format!(
						"{}: an observer has no IRC identity to change",
						rooms_application::failure::FailureCode::ReadOnlyMembership.wire()
					));
				}
				let [Argument::String(action), Argument::String(raw)] = args else {
					return Err("submitBridgeForm needs an action and its answers".into());
				};
				let answers = bridge::Answers::decode(raw).map_err(|e| e.to_string())?;
				let state = shared.borrow();
				let tls = state
					.irc
					.core
					.borrow()
					.network_of_bridge(&publication.key)
					.ok_or_else(retired)?
					.choice
					.tls;
				let replacement = match action.as_str() {
					seat::LINK_ACTION => Some(seat::read_identity(&answers, tls)?),
					seat::DISCONNECT_ACTION => None,
					_ => return Err(format!("this bridge form has no action {action}")),
				};
				let (shared, publication, seat) = (shared.clone(), publication.clone(), seat.clone());
				super::super::answer::later(&state, bridge::SUBMIT, async move {
					identity::change(&shared, &publication, &seat, replacement)
						.await
						.map(Argument::from)
				})
			}
			bridge::ASK if args.is_empty() => {
				let state = shared.borrow();
				let core = state.irc.core.borrow();
				let Some(view) = core.view(&publication.key, seat.connection) else {
					return Ok(Argument::Void);
				};
				let network = core.network_of_bridge(&publication.key).ok_or_else(retired)?;
				seat::identity_form(&view, &network.choice.endpoint(), network.choice.tls)
					.map_err(|e| e.to_string())?
					.encode()
					.map(Argument::from)
					.map_err(|e| e.to_string())
			}
			_ => Err(format!("IRC membership has no method {verb} with these arguments")),
		}
	}
}
