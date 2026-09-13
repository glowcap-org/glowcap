//! One member identity across a network's channels. Changes observe old
//! socket closure, and stale socket completions cannot change its replacement.
use super::*;
use crate::irc::{
	Endpoint,
	member::{self, Member, Status},
};
use futures_util::{StreamExt, stream::FuturesUnordered};

pub(in crate::server::irc) struct Identity {
	pub member: Member,
	pub network: String,
	pub connection: u64,
}
fn gate(state: &mut State, connection: u64, network: &str) -> Arc<Mutex<()>> {
	state.irc.identity_gates.retain(|_, held| held.strong_count() != 0);
	let key = (connection, network.to_owned());
	if let Some(held) = state.irc.identity_gates.get(&key).and_then(Weak::upgrade) {
		return held;
	}
	let gate = Arc::new(Mutex::new(()));
	state.irc.identity_gates.insert(key, Arc::downgrade(&gate));
	gate
}
fn network(state: &State, publication: &Publication) -> Result<String, String> {
	state
		.irc
		.core
		.borrow()
		.bridge(&publication.key)
		.map(|bridge| bridge.network.clone())
		.ok_or_else(retired)
}
fn seats(state: &State, connection: u64, network: &str) -> Vec<(Rc<Publication>, Rc<Seat>)> {
	state
		.irc
		.core
		.borrow()
		.identity(connection, network)
		.into_iter()
		.flat_map(|identity| identity.seats.iter())
		.filter_map(|key| {
			let publication = state.irc.publications.get(key)?.clone();
			let seat = publication.seats.borrow().get(&connection)?.clone();
			Some((publication, seat))
		})
		.collect()
}
fn detach(state: &mut State, connection: u64, network: &str) -> Option<Rc<Identity>> {
	for (_, seat) in seats(state, connection, network) {
		seat.channel.borrow_mut().take();
	}
	let identity = state.irc.identities.remove(&(connection, network.into()));
	if let Some(identity) = &identity {
		identity.member.stop();
	}
	identity
}
fn show_all(state: &State, connection: u64, network: &str, phase: Phase, nick: Option<&str>) {
	let keys = state
		.irc
		.core
		.borrow_mut()
		.show_identity(connection, network, phase, nick);
	for key in keys {
		if let Some(publication) = state.irc.publications.get(&key) {
			show(state, publication, connection);
		}
	}
}
pub(super) async fn ensure(
	shared: &Shared,
	publication: &Rc<Publication>,
	seat: &Rc<Seat>,
) -> Result<Rc<Identity>, String> {
	let (network, gate) = {
		let mut state = shared.borrow_mut();
		valid(&state, publication, seat)?;
		let network = network(&state, publication)?;
		let gate = gate(&mut state, seat.connection, &network);
		(network, gate)
	};
	let _held = gate.lock_owned().await;
	let ended = {
		let mut state = shared.borrow_mut();
		valid(&state, publication, seat)?;
		let ended = state
			.irc
			.identities
			.get(&(seat.connection, network.clone()))
			.is_some_and(|identity| matches!(*identity.member.changes().borrow(), Status::Ended(_)));
		if ended {
			detach(&mut state, seat.connection, &network)
		} else {
			None
		}
	};
	if let Some(ended) = ended {
		// tolerant: the member this one replaced is already out of the
		// roster; a close that fails leaves only its socket to the OS.
		let _ = ended.member.close().await;
	}
	let mut state = shared.borrow_mut();
	valid(&state, publication, seat)?;
	open(&mut state, publication, seat)
}
fn open(state: &mut State, publication: &Publication, seat: &Seat) -> Result<Rc<Identity>, String> {
	if state.irc.stopping || !publication.active.get() || !seat.active.get() {
		return Err(retired());
	}
	let core = state.irc.core.clone();
	let (network, choice, claimed) = {
		let core = core.borrow();
		let owner = core.network_of_bridge(&publication.key).ok_or_else(retired)?;
		let network = owner.choice.key();
		let claimed = core
			.identity(seat.connection, &network)
			.ok_or("this IRC identity ended")?;
		if !claimed.enabled {
			return Err("this identity is Rooms only; link it before posting to IRC".into());
		}
		(network, owner.choice.clone(), claimed.clone())
	};
	if let Some(identity) = state.irc.identities.get(&(seat.connection, network.clone())) {
		return Ok(identity.clone());
	}
	core.borrow()
		.speaker_fits(&publication.key, seat.connection)
		.map_err(|e| e.reason())?;
	let tls = state.irc.networks.get(&network).ok_or_else(retired)?.tls.clone();
	let endpoint = Endpoint::new(&choice.host, choice.port, choice.tls)?;
	let (member, worker) = member::open(endpoint, tls, &claimed.irc_nick, claimed.sasl)?;
	let mut changes = member.changes();
	let identity = Rc::new(Identity {
		member,
		connection: seat.connection,
		network: network.clone(),
	});
	state
		.irc
		.identities
		.insert((seat.connection, network), identity.clone());
	let (weak, held) = (Rc::downgrade(&state.shared()), Rc::downgrade(&identity));
	state.irc.tasks.spawn_local(async move {
		let run = worker.run();
		tokio::pin!(run);
		let result = loop {
			tokio::select! {
				result = &mut run => break result,
				changed = changes.changed() => {
					if changed.is_err() { continue; }
					let status = changes.borrow().clone();
					if let Status::Registered(nick) = status
						&& let (Some(shared), Some(identity)) = (weak.upgrade(), held.upgrade())
							&& let Err(reason) = observe_name(&shared, &identity, &nick) {
								identity.member.stop();
								break crate::cleanup::combine(Err(reason), run.as_mut().await);
							}
				}
			}
		};
		if let (Some(shared), Some(identity)) = (weak.upgrade(), held.upgrade()) {
			let state = shared.borrow();
			if identity_current(&state, &identity) && !state.irc.stopping {
				let notes = result
					.as_ref()
					.err()
					.map(|reason| {
						let core = state.irc.core.borrow();
						seats(&state, identity.connection, &identity.network)
							.into_iter()
							.filter_map(|(publication, seat)| {
								core.seat(&publication.key, seat.connection)
									.filter(|held| held.phase == Phase::Linked)
									.and_then(|_| core.bridge(&publication.key))
									.map(|bridge| {
										(publication.key.clone(), bridge.room.note_to(seat.connection, reason))
									})
							})
							.collect::<Vec<_>>()
					})
					.unwrap_or_default();
				show_all(&state, identity.connection, &identity.network, Phase::Failed, None);
				for (key, effects) in notes {
					if let Err(error) = apply(&state, &key, effects) {
						trouble(&state, "reporting IRC identity failure", error);
					}
				}
				if let Err(reason) = result {
					trouble(&state, "IRC member connection", reason);
				}
			}
		}
	});
	Ok(identity)
}
fn observe_name(shared: &Shared, identity: &Rc<Identity>, nick: &str) -> Result<(), String> {
	let state = shared.borrow();
	if !identity_current(&state, identity) {
		return Ok(());
	}
	let keys = {
		let mut core = state.irc.core.borrow_mut();
		let Some(claimed) = core.identity_mut(identity.connection, &identity.network) else {
			return Ok(());
		};
		if let Some(reason) = rooms_application::server::irc::registration::rename_refusal(&claimed.irc_nick, nick) {
			return Err(reason);
		}
		claimed.live_nick = nick.into();
		let keys: Vec<_> = claimed.seats.iter().cloned().collect();
		for key in &keys {
			if let Some(seat) = core.seat(key, identity.connection) {
				let phase = seat.phase;
				core.show_seat(key, identity.connection, phase, Some(nick));
			}
		}
		keys
	};
	for key in keys {
		if let Some(publication) = state.irc.publications.get(&key) {
			show(&state, publication, identity.connection);
		}
	}
	Ok(())
}

async fn join_all(shared: &Shared, connection: u64, network: &str, identity: Rc<Identity>) -> Result<(), String> {
	let held = seats(&shared.borrow(), connection, network);
	let mut pending = FuturesUnordered::new();
	for (publication, seat) in &held {
		let identity = identity.clone();
		pending.push(async move { (publication, seat, join_on(shared, publication, seat, identity).await) });
	}
	let mut failure = None;
	while let Some((publication, seat, result)) = pending.next().await {
		if let Err(reason) = result
			&& valid(&shared.borrow(), publication, seat).is_ok()
		{
			failure.get_or_insert(reason);
		}
	}
	match failure {
		Some(reason) => Err(reason),
		None => Ok(()),
	}
}
mod change;
pub(super) use change::change;
